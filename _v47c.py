import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

# extract the misplaced function (from its def to the line before Deep clean anchor)
start = s.index('// Probe unexplored stores that may back the inbox list hydration.')
end = s.index('            // Deep clean: purge EVERY injected-looking row for this thread.')
fn_text = s[start:end]
# remove from inside the handler
s = s[:start] + s[end:]

# re-insert at file scope: before MI_hInject definition
anchor = 'static void MI_hInject(NSString *threadIdIn, NSArray *messages) {'
assert s.count(anchor) == 1
s = s.replace(anchor, fn_text + anchor)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('probe function relocated to file scope')
