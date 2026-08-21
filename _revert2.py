import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

start = s.index('            // Inbox LIST renders snippet from sync-layer `threads`. Minimal update:')
end = s.index('            sqlite3_close(db);\n            [report appendFormat:@"')
ls = s.rfind('\n', 0, end) + 1
s = s[:start] + s[ls:]

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('sync threads write removed')
