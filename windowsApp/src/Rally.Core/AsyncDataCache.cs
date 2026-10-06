namespace Rally.Core;

// A navigation cancellation stops only that waiter. Shared requests have their
// own network timeout and can finish for other screens and the next navigation.
internal sealed class AsyncDataCache<T>(TimeSpan lifetime, int capacity = 128)
{
    private sealed class Entry { public T? Value; public DateTimeOffset At; public Task<T>? Pending; }
    private readonly Dictionary<string, Entry> _entries = new();
    private readonly object _gate = new();
    public Task<T> GetAsync(string key, Func<Task<T>> fetch, bool refresh, CancellationToken ct)
    {
        Task<T> task;
        lock (_gate)
        {
            if (!_entries.TryGetValue(key, out var entry))
            {
                if (_entries.Count >= capacity)
                    foreach (var old in _entries.Where(p => p.Value.Pending is null).OrderBy(p => p.Value.At).Take(Math.Max(1, capacity / 4)).Select(p => p.Key).ToArray()) _entries.Remove(old);
                _entries[key] = entry = new();
            }
            if (entry.Pending is not null) task = entry.Pending;
            else if (!refresh && entry.Value is not null && DateTimeOffset.UtcNow - entry.At < lifetime) task = Task.FromResult(entry.Value);
            else task = entry.Pending = Fetch(entry, fetch);
        }
        return task.WaitAsync(ct);
    }
    private async Task<T> Fetch(Entry entry, Func<Task<T>> fetch)
    {
        // Defer so Pending is assigned before even a synchronously completed fetch.
        await Task.Yield();
        try { var value = await fetch().ConfigureAwait(false); lock (_gate) { entry.Value = value; entry.At = DateTimeOffset.UtcNow; } return value; }
        finally { lock (_gate) entry.Pending = null; }
    }
    public void Clear() { lock (_gate) _entries.Clear(); }
}
