local _ = require("gettext")
return {
    fullname = _("MDict dictionaries"),
    -- The one place the version is set: releases are tagged v<version> (tools/release.sh checks),
    -- and the updater compares it with the latest release.
    version = "0.2.6",
    description = _([[Look up words in MDict (.mdx/.mdd) dictionaries from KOReader's dictionary popup,
with their original layout, including vertical Japanese.]]),
}
