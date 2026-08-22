import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

# ---- A) ledger tables at inject start (before Step 7) ----
anchorA = '            // Step 7: INSERT messages'
assert s.count(anchorA) == 1
ledgerA = '''            // Injection ledger: exact pks of OUR rows (for precise cleanup)
            sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS mi_ledger_cm (pk INTEGER PRIMARY KEY)", NULL, NULL, NULL);
            sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS mi_ledger_m (message_id TEXT PRIMARY KEY)", NULL, NULL, NULL);

''' + anchorA
s = s.replace(anchorA, ledgerA)

# ---- B) capture client pk after successful insert ----
old_b = '''                    if (rc2 == SQLITE_OK) {
                        [report appendFormat:@"       client_messages: inserted (pk~%lld)\\n", clientSortOrder];'''
assert s.count(old_b) == 1
new_b = '''                    if (rc2 == SQLITE_OK) {
                        sqlite3_exec(db, "INSERT OR IGNORE INTO mi_ledger_cm (pk) VALUES (last_insert_rowid())", NULL, NULL, NULL);
                        [report appendFormat:@"       client_messages: inserted (pk~%lld)\\n", clientSortOrder];'''
s = s.replace(old_b, new_b)

# ---- C) capture message_id after messages-table success ----
old_c = '''                        [report appendFormat:@"       messages: inserted\\n"];'''
if s.count(old_c) == 0:
    # find actual text around messages insert success
    import re
    m = re.search(r'(char \*err1 = NULL;.*?sqlite3_free\(err1);)', s, re.DOTALL)
print('step C needs real anchor - checking...')
