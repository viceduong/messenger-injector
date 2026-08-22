import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

# 1) fix doubled MI_hInject
doubled = 'static void MI_hInject(NSString *threadIdIn, NSArray *messages) {static void MI_hInject(NSString *threadIdIn, NSArray *messages) {'
assert s.count(doubled) == 1
s = s.replace(doubled, 'static void MI_hInject(NSString *threadIdIn, NSArray *messages) {')

# 2) remove misplaced bump calls (inside strings/wrong spots)
bad = '            MI_BumpSchema(db); // force render path to re-read (verified fix)\n'
n = s.count(bad)
s = s.replace(bad, '')
print('removed misplaced bumps:', n)

# 3) ensure MI_BumpSchema defined exactly once at file scope (before MI_repairRowCore comment)
defs = s.count('static void MI_BumpSchema(sqlite3 *db) {')
print('bump defs:', defs)
if defs == 0:
    anchorD = '// Core: clone a healthy threads row'
    i = s.index(anchorD)
    # back up to start of that comment line
    ls = s.rfind('\n', 0, i) + 1
    fn = '''// Schema-cookie bump: forces ALL connections to invalidate prepared
// statements and re-read the DB (verified protect->unprotect mechanism).
static void MI_BumpSchema(sqlite3 *db) {
    char *err = NULL;
    sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS mi_ledger_cm (pk INTEGER PRIMARY KEY)", NULL, NULL, NULL);
    sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS mi_ledger_m (message_id TEXT PRIMARY KEY)", NULL, NULL, NULL);
    sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS mi_touch_idx ON mi_ledger_m(message_id)", NULL, NULL, &err);
    if (err) sqlite3_free(err);
    sqlite3_exec(db, "DROP INDEX IF EXISTS mi_touch_idx", NULL, NULL, NULL);
}

'''
    s = s[:ls] + fn + s[ls:]
elif defs > 1:
    raise SystemExit("multiple defs - manual fix needed")

# 4) insert bump call at the RIGHT place: just before inject-path sqlite3_close
# find the inject close: pattern 'sqlite3_close(db);' preceded by our enforcer/probe section...
# unique anchor: '[report appendFormat:@"\\n=== Result' comes AFTER close; find close before it
ri = s.index('[report appendFormat:@"\\n=== Result')
ci = s.rindex('sqlite3_close(db);', 0, ri)
ls = s.rfind('\n', 0, ci) + 1
indent = s[ls:ci]
s = s[:ls] + indent + 'MI_BumpSchema(db);\n' + s[ls:]

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('all fixed')
