using System.Collections.Concurrent;

namespace NetherNet.Tests;

public sealed class ConnectionTests
{
    [Fact(Timeout = 30000)]
    public async Task DialerAndListenerExchangeReliablePackets()
    {
        var bus = new MemorySignalingBus();
        using var clientSignal = bus.Create("1");
        using var serverSignal = bus.Create("2");
        await using var listener = NetherNetListener.Listen(serverSignal, new ListenerOptions { AllowAnonymous = true });
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var accept = listener.AcceptAsync(timeout.Token).AsTask();
        await using var client = await new Dialer().DialAsync("2", clientSignal, timeout.Token);
        await using var server = await accept;
        var payload = "hello from the goat"u8.ToArray();
        Assert.Equal(payload.Length, await client.SendAsync(payload, cancellationToken: timeout.Token));
        Assert.Equal(payload, await server.ReceiveAsync(cancellationToken: timeout.Token));
    }

    private sealed class MemorySignalingBus
    {
        private readonly ConcurrentDictionary<string, MemorySignaling> _members = new();
        internal MemorySignaling Create(string id)
        {
            var value = new MemorySignaling(this, id);
            Assert.True(_members.TryAdd(id, value));
            return value;
        }
        internal MemorySignaling Get(string id) => _members[id];
    }

    private sealed class MemorySignaling(MemorySignalingBus bus, string id) : ISignaling, IDisposable
    {
        private readonly ConcurrentDictionary<long, INotifier> _notifiers = new();
        private readonly CancellationTokenSource _closed = new();
        private long _next;
        public CancellationToken Closed => _closed.Token;
        public string NetworkId => id;
        public ValueTask<Credentials?> GetCredentialsAsync(CancellationToken cancellationToken = default) => ValueTask.FromResult<Credentials?>(null);
        public IDisposable Notify(INotifier notifier)
        {
            var key = Interlocked.Increment(ref _next);
            _notifiers[key] = notifier;
            return new TestSubscription(() => _notifiers.TryRemove(key, out _));
        }

        public void SetPongData(ReadOnlySpan<byte> data)
        {
            _ = data;
        }
        public ValueTask SignalAsync(Signal signal, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var delivered = signal with { NetworkId = id };
            foreach (var notifier in bus.Get(signal.NetworkId)._notifiers.Values)
            {
                _ = notifier.NotifySignal(delivered);
            }

            return ValueTask.CompletedTask;
        }
        public void Dispose()
        {
            _closed.Cancel();
            _closed.Dispose();
            _notifiers.Clear();
        }
    }

    private sealed class TestSubscription(Action action) : IDisposable
    {
        private Action? _action = action;
        public void Dispose() => Interlocked.Exchange(ref _action, null)?.Invoke();
    }
}
