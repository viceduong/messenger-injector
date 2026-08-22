import io
p = 'D:/agentic-fm/messenger-injector/dylib/MessengerInjector.m'
s = io.open(p, encoding='utf-8').read()

# fwd decl
old0 = 'static void MI_hMark(NSString *threadId);'
if s.count(old0) == 1:
    s = s.replace(old0, old0 + '\nstatic void MI_hRepairRow(NSString *threadId);')

# notification constant
old1 = 'static NSString *const kNotifyMark    = @"com.messenger.injector.mark";'
assert s.count(old1) == 1
s = s.replace(old1, old1 + '\nstatic NSString *const kNotifyRepair  = @"com.messenger.injector.repair";')

# observer
old_obs = '''        [dnc addObserverForName:kNotifyMark object:nil queue:[NSOperationQueue mainQueue]'''
assert s.count(old_obs) == 1
idx = s.index(old_obs)
line_end = s.index('\n', idx)
insert_after = s.index('\n', line_end + 1)
repair_obs = '''
        [dnc addObserverForName:kNotifyRepair object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { @try { MI_hRepairRow(n.userInfo[@"threadId"] ?: @""); } @catch (NSException *e) { MI_progress([NSString stringWithFormat:@"repair obs: %@", e.name]); } }];'''
s = s[:insert_after] + repair_obs + s[insert_after:]

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('decl+obs done')
