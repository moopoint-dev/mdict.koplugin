package org.koreader.mdict;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.ComponentCallbacks2;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.Choreographer;
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
 *   {"ev":"loaded","slot":s,"renewIn":ms}       document finished loading; after ms, the next
 *                                               load() gives the slot a new WebView
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
    // A capture draws once the WebView has drawn the pager's latest state: when its
    // visual state callback comes (two animation frames later where there is none), or
    // after this at the latest. On e-readers a frame can take a third of a second, and
    // a few seconds after a large picture viewer closes.
    private static final int CAPTURE_WAIT_MS = 3000;
    // On e-readers a WebView's captures wait longer the older it is, however little it is
    // used: in one test the median wait was 25 ms in its first 10 s, 250 ms at 30 to 60 s
    // and 1 s after 150 s, while drawing stayed at 10 ms. A new WebView in the same process
    // is fast again, and loading a document into one costs only 20 to 40 ms more. So a slot
    // gets a new WebView with its next document once a capture waited longer than this, or
    // once its WebView is older than RENEW_AGE_MS (the Lua side then reloads a document it
    // would otherwise keep).
    private static final int SLOW_CAPTURE_MS = 1500;
    private static final long RENEW_AGE_MS = 30 * 1000;

    private final Activity activity;
    private final Handler ui;
    private final LinkedBlockingQueue<byte[]> events = new LinkedBlockingQueue<byte[]>();
    private final ConcurrentHashMap<Integer, ArrayBlockingQueue<String>> needs =
            new ConcurrentHashMap<Integer, ArrayBlockingQueue<String>>();
    private final AtomicInteger nextRid = new AtomicInteger(1);
    private final Map<Integer, Slot> slots = new ConcurrentHashMap<Integer, Slot>();
    // captures waiting for their animation frames, by id
    private final Map<Integer, Runnable> framed = new ConcurrentHashMap<Integer, Runnable>();
    // bitmaps shared by all slots, by size (pages of horizontal and of vertical entries
    // differ by the scroll bar): captures run one at a time on the UI thread (UI thread only)
    private final Map<Long, Bitmap> bitmaps = new HashMap<Long, Bitmap>();

    private final class Slot {
        final int id;
        WebView view;
        volatile String host = "";
        volatile File cacheRoot;
        volatile Map<String, File> files = new HashMap<String, File>();
        final ConcurrentHashMap<Integer, String> args = new ConcurrentHashMap<Integer, String>();
        volatile boolean renew; // the next document gets a new WebView
        long born; // when the WebView was made (uptime, UI thread only)

        Slot(int id) { this.id = id; }
    }

    public HtmlRenderer(Activity activity) {
        this.activity = activity;
        this.ui = new Handler(Looper.getMainLooper());
        // for the log: WebViews release memory when the system asks for it
        activity.registerComponentCallbacks(new ComponentCallbacks2() {
            @Override public void onTrimMemory(int level) { Log.i(TAG, "trim memory " + level); }
            @Override public void onLowMemory() { Log.i(TAG, "low memory"); }
            @Override public void onConfigurationChanged(Configuration c) { }
        });
    }

    /** 2: playAudio/stopAudio. 3: audioState. */
    public static int version() { return 3; }

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

    /** Replaces the slot's WebView with a new one of the same size. (UI thread only) */
    private void replaceView(Slot s) {
        long t = SystemClock.uptimeMillis();
        s.renew = false;
        WebView old = s.view;
        ViewGroup.LayoutParams lp = old.getLayoutParams();
        int width = lp.width, height = lp.height;
        ViewGroup parent = (ViewGroup) old.getParent();
        if (parent != null) parent.removeView(old);
        old.stopLoading();
        old.destroy();
        s.view = createView(s);
        activity.addContentView(s.view, new ViewGroup.LayoutParams(width, height));
        layout(s.view, width, height);
        Log.i(TAG, "slot " + s.id + ": new WebView in " + (SystemClock.uptimeMillis() - t) + " ms");
    }

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    private WebView createView(final Slot s) {
        s.born = SystemClock.uptimeMillis();
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
                    if (s.renew || SystemClock.uptimeMillis() - s.born > RENEW_AGE_MS) replaceView(s);
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
        final long asked = SystemClock.uptimeMillis();
        ui.post(new Runnable() {
            @Override public void run() {
                final Slot s = slots.get(slot);
                if (s == null) { emitCaptured(slot, id, false, 0, 0, "none", false, ""); return; }
                final long start = SystemClock.uptimeMillis();
                final boolean[] fired = {false};
                // for the log: when the UI thread got to it, and when the next vsync came
                final long queued = start - asked;
                final long[] vsync = {-1};
                Choreographer.getInstance().postFrameCallback(new Choreographer.FrameCallback() {
                    @Override public void doFrame(long frameTimeNanos) { vsync[0] = SystemClock.uptimeMillis() - start; }
                });
                final class Draw implements Runnable {
                    final String via;
                    Draw(String via) { this.via = via; }
                    @Override public void run() {
                        if (fired[0]) return;
                        fired[0] = true;
                        framed.remove(id);
                        long t = SystemClock.uptimeMillis();
                        boolean ok = drawInto(s, dst, width, height);
                        long done = SystemClock.uptimeMillis();
                        if (!s.renew && t - start > SLOW_CAPTURE_MS) {
                            s.renew = true;
                            Log.i(TAG, "slot " + slot + ": capture waited " + (t - start) + " ms: new WebView with the next document");
                        } else if (!s.renew && t - s.born > RENEW_AGE_MS) {
                            s.renew = true;
                            Log.i(TAG, "slot " + slot + ": WebView " + (t - s.born) / 1000 + " s old: new WebView with the next document");
                        }
                        emitCaptured(slot, id, ok, t - start, done - t, via, s.renew,
                                ", queued " + queued + " ms, vsync " + vsync[0] + " ms");
                    }
                }
                if (Build.VERSION.SDK_INT >= 23) {
                    final Draw onState = new Draw("state");
                    s.view.postVisualStateCallback(id, new WebView.VisualStateCallback() {
                        @Override public void onComplete(long requestId) { onState.run(); }
                    });
                } else {
                    // no visual state callbacks: two animation frames instead (only here, as
                    // the WebView then draws those frames too)
                    framed.put(id, new Draw("frames"));
                    s.view.evaluateJavascript("requestAnimationFrame(function(){requestAnimationFrame(function(){"
                            + "KOBridge.framed(" + id + ")})})", null);
                }
                ui.postDelayed(new Draw("timeout"), CAPTURE_WAIT_MS);
            }
        });
    }

    private boolean drawInto(Slot s, ByteBuffer dst, int width, int height) {
        try {
            if (s.view.getWidth() != width || s.view.getHeight() != height) layout(s.view, width, height);
            Long size = ((long) width << 32) | height;
            Bitmap bitmap = bitmaps.get(size);
            if (bitmap == null) {
                if (bitmaps.size() >= 2) {
                    for (Bitmap b : bitmaps.values()) b.recycle();
                    bitmaps.clear();
                }
                bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
                bitmaps.put(size, bitmap);
            }
            bitmap.eraseColor(Color.WHITE);
            Canvas c = new Canvas(bitmap);
            s.view.draw(c);
            dst.rewind();
            bitmap.copyPixelsToBuffer(dst);
            return true;
        } catch (Throwable t) {
            emitError(s.id, t);
            return false;
        }
    }

    private void emitCaptured(int slot, int id, boolean ok, long waitMs, long drawMs, String via, boolean renew,
                              String more) {
        Log.d(TAG, "slot " + slot + ": capture " + id + ": waited " + waitMs + " ms (" + via + "), drew in " + drawMs
                + " ms" + more);
        emit("{\"ev\":\"captured\",\"slot\":" + slot + ",\"id\":" + id + ",\"ok\":" + ok
                + ",\"wait\":" + waitMs + ",\"draw\":" + drawMs + ",\"via\":\"" + via + "\""
                + (renew ? ",\"renew\":true" : "") + "}");
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
                if (slots.isEmpty()) {
                    for (Bitmap b : bitmaps.values()) b.recycle();
                    bitmaps.clear();
                }
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

    // What audioState reports on the sound started last: its number, whether it is being
    // prepared (1), plays (2) or neither (0), and its timing. Set on the UI thread, read on any.
    private volatile int audioSerial, audioStatus, audioDuration;
    private volatile long audioStart;

    /** Plays an audio file, stopping the one playing. Failures (unsupported formats) are logged. */
    public void playAudio(byte[] path) {
        final String p = str(path);
        final int serial;
        synchronized (this) {
            serial = ++audioSerial;
            audioStatus = 1;
            audioDuration = 0;
        }
        ui.post(new Runnable() {
            @Override public void run() {
                stopPlayer();
                audioStatus = 1; // this one, or one that came after it, is being prepared
                if (serial != audioSerial) return;
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
                            if (player != m) return;
                            audioDuration = Math.max(0, m.getDuration());
                            audioStart = SystemClock.uptimeMillis();
                            audioStatus = 2;
                            m.start();
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

    /** The sound started last, as "serial status positionMs durationMs": status 1 while it is
     *  prepared, 2 while it plays, 0 once it has ended or was stopped (or failed). */
    public byte[] audioState() {
        int status = audioStatus;
        long pos = status == 2 ? SystemClock.uptimeMillis() - audioStart : 0;
        int dur = audioDuration;
        if (dur > 0 && pos > dur) pos = dur;
        try {
            return (audioSerial + " " + status + " " + pos + " " + dur).getBytes("UTF-8");
        } catch (Exception e) {
            return new byte[0];
        }
    }

    private void stopPlayer() {
        MediaPlayer mp = player;
        player = null;
        audioStatus = 0;
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

        /** Two animation frames have passed since capture `id` was asked for. */
        @JavascriptInterface public void framed(final int id) {
            ui.post(new Runnable() {
                @Override public void run() {
                    Runnable draw = framed.get(id);
                    if (draw != null) draw.run();
                }
            });
        }
    }

    // ---- resources ----------------------------------------------------------

    private final class Client extends WebViewClient {
        private final Slot s;
        Client(Slot s) { this.s = s; }

        @Override public void onPageFinished(WebView view, String url) {
            long renewIn = Math.max(0, RENEW_AGE_MS - (SystemClock.uptimeMillis() - s.born));
            emit("{\"ev\":\"loaded\",\"slot\":" + s.id + ",\"renewIn\":" + renewIn + "}");
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
