std = "luajit"
unused_args = false
max_line_length = 130
self = false
read_globals = { "G_reader_settings", "G_defaults" }
files["spec/"] = { std = "+busted" }
exclude_files = { "mdict.koplugin/mdict/kosort1_tables.lua", ".devtools/", ".sync/" }
