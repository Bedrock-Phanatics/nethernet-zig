using System.Security.Cryptography;
using NetherNet.Endpoint;
using SIPSorcery.Net;

namespace NetherNet.Tests;

public sealed class SafetyTests
{
    [Fact]
    public async Task EndpointBodyReaderRejectsChunkedBodyOverLimit()
    {
        var body = new byte[EndpointClient.MaximumSdpBodySize + 1];
        await using var stream = new MemoryStream(body);
        Assert.Null(await EndpointHandler.ReadBodyAsync(stream, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task EndpointBodyReaderAcceptsBodyAtLimit()
    {
        var body = new byte[EndpointClient.MaximumSdpBodySize];
        await using var stream = new MemoryStream(body);
        var result = await EndpointHandler.ReadBodyAsync(stream, TestContext.Current.CancellationToken);
        Assert.NotNull(result);
        Assert.Equal(body.Length, result.Length);
    }

    [Fact]
    public async Task ListenerRejectsOffersBeyondNegotiationLimit()
    {
        using var signaling = new BlockingSignaling();
        await using var listener = NetherNetListener.Listen(signaling, new ListenerOptions
        {
            AllowAnonymous = true,
            MaximumConcurrentNegotiations = 1
        });
        var first = new Signal { Type = SignalTypes.Offer, ConnectionId = 1, NetworkId = "remote", Data = "v=0" };
        var second = first with { ConnectionId = 2 };

        Assert.True(listener.NotifySignal(first));
        await signaling.CredentialsRequested.Task.WaitAsync(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken);
        Assert.False(listener.NotifySignal(second));
    }

    [Fact]
    public async Task PendingSendCompletesWhenConnectionCloses()
    {
        var peer = new RTCPeerConnection();
        await using var connection = new NetherNetConnection(peer, 1, "remote", "local");
        var send = connection.SendAsync(new byte[] { 1, 2, 3 }, cancellationToken: TestContext.Current.CancellationToken).AsTask();

        connection.Dispose();

        var completed = await Task.WhenAny(send, Task.Delay(TimeSpan.FromSeconds(2), TestContext.Current.CancellationToken));
        Assert.Same(send, completed);
        await Assert.ThrowsAnyAsync<Exception>(() => send);
    }

    [Fact]
    public async Task EmptyReadReturnsWithoutWaitingForPacket()
    {
        var peer = new RTCPeerConnection();
        await using var connection = new NetherNetConnection(peer, 1, "remote", "local");
        Assert.Equal(0, await connection.ReadAsync(Memory<byte>.Empty, TestContext.Current.CancellationToken));
    }

    [Fact]
    public void ConnectionDisposesOwnedPublicKey()
    {
        var peer = new RTCPeerConnection();
        var connection = new NetherNetConnection(peer, 1, "remote", "local");
        var key = ECDsa.Create(ECCurve.NamedCurves.nistP384);
        connection.SetPublicKey(key, ownsKey: true);

        connection.Dispose();

        Assert.Throws<ObjectDisposedException>(() => key.ExportParameters(false));
    }

    private sealed class BlockingSignaling : ISignaling, IDisposable
    {
        private readonly CancellationTokenSource _closed = new();
        internal TaskCompletionSource CredentialsRequested { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public CancellationToken Closed => _closed.Token;
        public string NetworkId => "local";

        public async ValueTask<Credentials?> GetCredentialsAsync(CancellationToken cancellationToken = default)
        {
            CredentialsRequested.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return null;
        }

        public IDisposable Notify(INotifier notifier) => new TestSubscription();
        public void SetPongData(ReadOnlySpan<byte> data)
        {
            // NOOP
        }
        public ValueTask SignalAsync(Signal signal, CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
        public void Dispose() { _closed.Cancel(); _closed.Dispose(); }
    }

    private sealed class TestSubscription : IDisposable
    {
        public void Dispose()
        {
            // NOOP
        }
    }
}
