package org.koreader.mdict;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.JavascriptInterface;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.net.URI;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Offscreen WebView renderer driven from KOReader's Lua thread over JNI.
 *
 * Every public method may be called from any thread and returns at once; work
 * that touches a WebView runs on the UI thread. Results come back as UTF-8
 * JSON events that the Lua side collects with {@link #poll(int)}:
 *
 *   {"ev":"loaded","slot":s}                    document finished loading
 *   {"ev":"done","slot":s,"id":n,"r":<json>}    a pager op finished
 *   {"ev":"need","slot":s,"rid":n,"path":"..."} a resource is missing from the cache;
 *                                               answer with provide(rid, file)
 *   {"ev":"captured","slot":s,"id":n,"ok":b}    a page was drawn into the caller's buffer
 *   {"ev":"error","slot":s,"msg":"..."}
 *
 * A slot is one WebView holding one pager document. Pages are drawn with
 * View.draw into a software bitmap, so the WebView never needs to be on
 * screen; it stays attached to the activity (for layout and timers) with
 * zero alpha, below KOReader's own surface.
 */
@SuppressWarnings({"deprecation", "unused"})
public final class HtmlRenderer {
    private static final String TAG = "MDictRenderer";
    private static final String HOST_SUFFIX = ".mdict.local";
    private static final int NEED_TIMEOUT_MS = 4000;
    private static final int VISUAL_STATE_TIMEOUT_MS = 400;

    private final Activity activity;
    private final Handler ui;
    private final LinkedBlockingQueue<byte[]> events = new LinkedBlockingQueue<byte[]>();
    private final ConcurrentHashMap<Integer, ArrayBlockingQueue<String>> needs =
            new ConcurrentHashMap<Integer, ArrayBlockingQueue<String>>();
    private final AtomicInteger nextRid = new AtomicInteger(1);
    private final Map<Integer, Slot> slots = new ConcurrentHashMap<Integer, Slot>();

    private final class Slot {
        final int id;
        WebView view;
        volatile String host = "";
        volatile File cacheRoot;
        volatile Map<String, File> files = new HashMap<String, File>();
        final ConcurrentHashMap<Integer, String> args = new ConcurrentHashMap<Integer, String>();
        Bitmap bitmap;

        Slot(int id) { this.id = id; }
    }

    public HtmlRenderer(Activity activity) {
        this.activity = activity;
        this.ui = new Handler(Looper.getMainLooper());
    }

    /** 2: playAudio/stopAudio. */
    public static int version() { return 2; }

    // ---- events -------------------------------------------------------------

    private void emit(String json) {
        try {
            events.offer(json.getBytes("UTF-8"));
        } catch (Exception e) {
            Log.e(TAG, "emit", e);
        }
    }

    private void emitError(int slot, Throwable t) {
        Log.e(TAG, "slot " + slot, t);
        emit("{\"ev\":\"error\",\"slot\":" + slot + ",\"msg\":" + JSONObject.quote(String.valueOf(t)) + "}");
    }

    /** Next event as UTF-8 JSON, or null after timeoutMs. */
    public byte[] poll(int timeoutMs) {
        try {
            return timeoutMs <= 0 ? events.poll() : events.poll(timeoutMs, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
            return null;
        }
    }

    /** Drops queued events (stale results of a cancelled operation). */
    public void drain() {
        events.clear();
    }

    private static String str(byte[] b) {
        if (b == null) return null;
        try {
            return new String(b, "UTF-8");
        } catch (Exception e) {
            return null;
        }
    }

    // ---- slots --------------------------------------------------------------

    /** Creates (or resizes) a slot's WebView, width and height in device pixels. */
    public void open(final int slot, final int width, final int height) {
        ui.post(new Runnable() {
            @Override public void run() {
                try {
                    Slot s = slots.get(slot);
                    if (s == null) {
                        s = new Slot(slot);
                        s.view = createView(s);
                        slots.put(slot, s);
                        activity.addContentView(s.view, new ViewGroup.LayoutParams(width, height));
                    } else {
                        ViewGroup.LayoutParams lp = s.view.getLayoutParams();
                        lp.width = width;
                        lp.height = height;
                        s.view.setLayoutParams(lp);
                    }
                    layout(s.view, width, height);
                    emit("{\"ev\":\"opened\",\"slot\":" + slot + "}");
                } catch (Throwable t) {
                    emitError(slot, t);
                }
            }
        });
    }

    private static void layout(View v, int width, int height) {
        v.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY));
        v.layout(0, 0, width, height);
    }

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    private WebView createView(final Slot s) {
        WebView v = new WebView(activity);
        v.setAlpha(0f);
        v.setBackgroundColor(Color.WHITE);
        v.setVerticalScrollBarEnabled(false);
        v.setHorizontalScrollBarEnabled(false);
        v.setOverScrollMode(View.OVER_SCROLL_NEVER);
        v.setFocusable(false);
        WebSettings ws = v.getSettings();
        ws.setJavaScriptEnabled(true);
        ws.setAllowFileAccess(false);
        ws.setAllowContentAccess(false);
        ws.setGeolocationEnabled(false);
        ws.setSaveFormData(false);
        ws.setSupportZoom(false);
        ws.setBuiltInZoomControls(false);
        ws.setUseWideViewPort(false);
        ws.setLoadWithOverviewMode(false);
        ws.setTextZoom(100);
        ws.setMinimumFontSize(1);
        ws.setMinimumLogicalFontSize(1);
        ws.setDefaultTextEncodingName("utf-8");
        ws.setCacheMode(WebSettings.LOAD_NO_CACHE);
        ws.setMediaPlaybackRequiresUserGesture(true);
        if (Build.VERSION.SDK_INT >= 29) {
            ws.setForceDark(WebSettings.FORCE_DARK_OFF);
        }
        v.addJavascriptInterface(new Bridge(s), "KOBridge");
        v.setWebViewClient(new Client(s));
        return v;
    }

    /** Loads a pager document. baseUrl is https://<dict>.mdict.local/; cacheRoot holds
     *  extracted resources by path; files maps /__file__/<token> to absolute paths. */
    public void load(final int slot, byte[] baseUrl, byte[] html, byte[] cacheRoot, byte[] filesJson) {
        final String base = str(baseUrl), doc = str(html), root = str(cacheRoot), files = str(filesJson);
        ui.post(new Runnable() {
            @Override public void run() {
                Slot s = slots.get(slot);
                if (s == null) { emitError(slot, new IllegalStateException("no such slot")); return; }
                try {
                    s.host = URI.create(base).getHost();
                    s.cacheRoot = new File(root);
                    Map<String, File> map = new HashMap<String, File>();
                    if (files != null && files.length() > 0) {
                        JSONObject o = new JSONObject(files);
                        java.util.Iterator<String> it = o.keys();
                        while (it.hasNext()) {
                            String k = it.next();
                            map.put(k, new File(o.getString(k)));
                        }
                    }
                    s.files = map;
                    s.args.clear();
                    s.view.loadDataWithBaseURL(base, doc, "text/html", "utf-8", null);
                } catch (Throwable t) {
                    emitError(slot, t);
                }
            }
        });
    }

    /** Runs window.MDict[op](id) with args (JSON); emits "done" when the pager answers. */
    public void call(final int slot, final int id, byte[] op, byte[] argsJson) {
        final String name = str(op), args = str(argsJson);
        final Slot s = slots.get(slot);
        if (s == null) { emitError(slot, new IllegalStateException("no such slot")); return; }
        s.args.put(id, args == null ? "{}" : args);
        ui.post(new Runnable() {
            @Override public void run() {
                try {
                    s.view.evaluateJavascript("window.MDict&&MDict." + name + "(" + id + ")", null);
                } catch (Throwable t) {
                    emitError(slot, t);
                }
            }
        });
    }

    /** Draws the slot's current state into dst (RGBA, width*4 bytes per row). */
    public void capture(final int slot, final int id, final ByteBuffer dst, final int width, final int height) {
        ui.post(new Runnable() {
            @Override public void run() {
                final Slot s = slots.get(slot);
                if (s == null) { emitCaptured(slot, id, false); return; }
                final boolean[] fired = {false};
                final Runnable draw = new Runnable() {
                    @Override public void run() {
                        if (fired[0]) return;
                        fired[0] = true;
                        emitCaptured(slot, id, drawInto(s, dst, width, height));
                    }
                };
                if (Build.VERSION.SDK_INT >= 23) {
                    s.view.postVisualStateCallback(id, new WebView.VisualStateCallback() {
                        @Override public void onComplete(long requestId) { draw.run(); }
                    });
                    ui.postDelayed(draw, VISUAL_STATE_TIMEOUT_MS);
                } else {
                    ui.postDelayed(draw, 50);
                }
            }
        });
    }

    private boolean drawInto(Slot s, ByteBuffer dst, int width, int height) {
        try {
            if (s.view.getWidth() != width || s.view.getHeight() != height) layout(s.view, width, height);
            if (s.bitmap == null || s.bitmap.getWidth() != width || s.bitmap.getHeight() != height) {
                if (s.bitmap != null) s.bitmap.recycle();
                s.bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            }
            s.bitmap.eraseColor(Color.WHITE);
            Canvas c = new Canvas(s.bitmap);
            s.view.draw(c);
            dst.rewind();
            s.bitmap.copyPixelsToBuffer(dst);
            return true;
        } catch (Throwable t) {
            emitError(s.id, t);
            return false;
        }
    }

    private void emitCaptured(int slot, int id, boolean ok) {
        emit("{\"ev\":\"captured\",\"slot\":" + slot + ",\"id\":" + id + ",\"ok\":" + ok + "}");
    }

    /** Answers a "need" event: the file now in the cache, or null/empty if there is none. */
    public void provide(int rid, byte[] path) {
        ArrayBlockingQueue<String> q = needs.get(rid);
        if (q != null) {
            String p = str(path);
            q.offer(p == null ? "" : p);
        }
    }

    public void close(final int slot) {
        ui.post(new Runnable() {
            @Override public void run() {
                Slot s = slots.remove(slot);
                if (s == null) return;
                try {
                    ViewGroup parent = (ViewGroup) s.view.getParent();
                    if (parent != null) parent.removeView(s.view);
                    s.view.stopLoading();
                    s.view.destroy();
                } catch (Throwable t) {
                    Log.e(TAG, "close", t);
                }
                if (s.bitmap != null) s.bitmap.recycle();
            }
        });
    }

    public void closeAll() {
        for (Integer id : slots.keySet()) close(id);
        // release any request thread still waiting on Lua
        for (ArrayBlockingQueue<String> q : needs.values()) q.offer("");
        stopAudio();
    }

    // ---- audio --------------------------------------------------------------------

    private MediaPlayer player; // UI thread only

    /** Plays an audio file, stopping the one playing. Failures (unsupported formats) are logged. */
    public void playAudio(byte[] path) {
        final String p = str(path);
        ui.post(new Runnable() {
            @Override public void run() {
                stopPlayer();
                FileInputStream in = null;
                try {
                    final MediaPlayer mp = new MediaPlayer();
                    player = mp;
                    if (Build.VERSION.SDK_INT >= 21) {
                        mp.setAudioAttributes(new AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                .build());
                    }
                    in = new FileInputStream(p);
                    mp.setDataSource(in.getFD()); // the player keeps its own descriptor
                    mp.setOnPreparedListener(new MediaPlayer.OnPreparedListener() {
                        @Override public void onPrepared(MediaPlayer m) {
                            if (player == m) m.start();
                        }
                    });
                    mp.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
                        @Override public void onCompletion(MediaPlayer m) {
                            if (player == m) stopPlayer();
                        }
                    });
                    mp.setOnErrorListener(new MediaPlayer.OnErrorListener() {
                        @Override public boolean onError(MediaPlayer m, int what, int extra) {
                            Log.w(TAG, "audio error " + what + "/" + extra + ": " + p);
                            if (player == m) stopPlayer();
                            return true;
                        }
                    });
                    mp.prepareAsync();
                } catch (Throwable t) {
                    Log.e(TAG, "audio " + p, t);
                    stopPlayer();
                } finally {
                    if (in != null) {
                        try { in.close(); } catch (Exception ignored) { }
                    }
                }
            }
        });
    }

    public void stopAudio() {
        ui.post(new Runnable() {
            @Override public void run() { stopPlayer(); }
        });
    }

    private void stopPlayer() {
        MediaPlayer mp = player;
        player = null;
        if (mp == null) return;
        try { mp.reset(); } catch (Throwable ignored) { }
        mp.release();
    }

    // ---- JavaScript bridge ------------------------------------------------------

    private final class Bridge {
        private final Slot s;
        Bridge(Slot s) { this.s = s; }

        @JavascriptInterface public String arg(int id) {
            String a = s.args.remove(id);
            return a == null ? "{}" : a;
        }

        @JavascriptInterface public void done(int id, String json) {
            emit("{\"ev\":\"done\",\"slot\":" + s.id + ",\"id\":" + id + ",\"r\":" + (json == null ? "null" : json) + "}");
        }

        @JavascriptInterface public void log(String msg) {
            Log.i(TAG, "js: " + msg);
        }
    }

    // ---- resources ----------------------------------------------------------

    private final class Client extends WebViewClient {
        private final Slot s;
        Client(Slot s) { this.s = s; }

        @Override public void onPageFinished(WebView view, String url) {
            emit("{\"ev\":\"loaded\",\"slot\":" + s.id + "}");
        }

        @Override public boolean shouldOverrideUrlLoading(WebView view, String url) {
            return true; // navigation is handled by KOReader through the pager's link list
        }

        @Override public WebResourceResponse shouldInterceptRequest(WebView view, String url) {
            try {
                return serve(s, url);
            } catch (Throwable t) {
                Log.e(TAG, "intercept " + url, t);
                return empty();
            }
        }
    }

    private static WebResourceResponse empty() {
        return new WebResourceResponse("text/plain", "utf-8", new ByteArrayInputStream(new byte[0]));
    }

    private WebResourceResponse serve(Slot s, String url) throws Exception {
        URI uri = URI.create(url);
        String host = uri.getHost();
        if (!"https".equals(uri.getScheme()) || host == null || !host.equals(s.host) || !host.endsWith(HOST_SUFFIX)) {
            return empty(); // nothing leaves the device
        }
        String path = uri.getPath();
        if (path == null) return empty();
        File file;
        if (path.startsWith("/__file__/")) {
            file = s.files.get(path.substring(10));
        } else {
            String rel = path.startsWith("/") ? path.substring(1) : path;
            if (rel.length() == 0 || rel.contains("..")) return empty();
            file = new File(s.cacheRoot, rel);
            if (!file.isFile()) file = request(s, rel);
        }
        if (file == null || !file.isFile()) return empty();
        InputStream in = new FileInputStream(file);
        WebResourceResponse r = new WebResourceResponse(mimeOf(file.getName()), null, in);
        if (Build.VERSION.SDK_INT >= 21) {
            Map<String, String> h = new HashMap<String, String>();
            h.put("Access-Control-Allow-Origin", "*");
            h.put("Cache-Control", "max-age=86400");
            r.setResponseHeaders(h);
        }
        return r;
    }

    /** Asks Lua to extract a resource, waiting on this request thread for the answer. */
    private File request(Slot s, String rel) {
        int rid = nextRid.getAndIncrement();
        ArrayBlockingQueue<String> q = new ArrayBlockingQueue<String>(1);
        needs.put(rid, q);
        try {
            emit("{\"ev\":\"need\",\"slot\":" + s.id + ",\"rid\":" + rid + ",\"path\":" + JSONObject.quote(rel) + "}");
            String answer = q.poll(NEED_TIMEOUT_MS, TimeUnit.MILLISECONDS);
            return answer == null || answer.length() == 0 ? null : new File(answer);
        } catch (InterruptedException e) {
            return null;
        } finally {
            needs.remove(rid);
        }
    }

    private static String mimeOf(String name) {
        String n = name.toLowerCase(Locale.ROOT);
        int dot = n.lastIndexOf('.');
        String ext = dot < 0 ? "" : n.substring(dot + 1);
        if (ext.equals("css")) return "text/css";
        if (ext.equals("js")) return "text/javascript";
        if (ext.equals("png")) return "image/png";
        if (ext.equals("jpg") || ext.equals("jpeg")) return "image/jpeg";
        if (ext.equals("gif")) return "image/gif";
        if (ext.equals("svg")) return "image/svg+xml";
        if (ext.equals("webp")) return "image/webp";
        if (ext.equals("bmp")) return "image/bmp";
        if (ext.equals("ttf")) return "font/ttf";
        if (ext.equals("otf")) return "font/otf";
        if (ext.equals("woff")) return "font/woff";
        if (ext.equals("woff2")) return "font/woff2";
        if (ext.equals("html") || ext.equals("htm")) return "text/html";
        if (ext.equals("mp3")) return "audio/mpeg";
        if (ext.equals("aac")) return "audio/aac";
        if (ext.equals("ogg") || ext.equals("oga")) return "audio/ogg";
        if (ext.equals("wav")) return "audio/wav";
        return "application/octet-stream";
    }
}
