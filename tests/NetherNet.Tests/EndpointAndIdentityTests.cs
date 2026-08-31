using System.Net;
using System.Text;
using System.Text.Json;
using NetherNet.Endpoint;

namespace NetherNet.Tests;

public sealed class EndpointAndIdentityTests
{
    [Fact]
    public void IdentityAssertionUsesNestedJsonStringShape()
    {
        var value = new IdentityData(
            new IdentityAssertion("header..signature", "header.payload.signature"),
            new IdentityProvider("self", "default"));
        var json = JsonSerializer.Serialize(value);
        using var document = JsonDocument.Parse(json);
        Assert.Equal(JsonValueKind.String, document.RootElement.GetProperty("assertion").ValueKind);
        var decoded = JsonSerializer.Deserialize<IdentityData>(json);
        Assert.Equal(value, decoded);
    }

    [Fact]
    public async Task EndpointClientAcceptsExplicitDefaultPort()
    {
        using var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("v=0\r\n", Encoding.UTF8, "application/sdp")
        });
        using var httpClient = new HttpClient(handler);
        using var client = new EndpointClient(new EndpointClientOptions
        {
            HttpClient = httpClient,
            NetworkId = "1"
        });
        var recorder = new Recorder();
        using var subscription = client.Notify(recorder);
        await client.SignalAsync(new Signal
        {
            Type = SignalTypes.Offer,
            ConnectionId = 2,
            NetworkId = "https://localhost:443",
            Data = "offer"
        }, TestContext.Current.CancellationToken);
        Assert.Equal("v=0\r\n", Assert.Single(recorder.Signals).Data);
        Assert.Equal(443, handler.Request!.RequestUri!.Port);
    }

    [Fact]
    public async Task EndpointClientRejectsNumericNegotiationError()
    {
        using var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("37")
        });
        using var httpClient = new HttpClient(handler);
        using var client = new EndpointClient(new EndpointClientOptions
        {
            HttpClient = httpClient
        });
        var exception = await Assert.ThrowsAsync<InvalidDataException>(() => client.SignalAsync(
            new Signal
            {
                Type = SignalTypes.Offer,
                ConnectionId = 2,
                NetworkId = "http://localhost:8080",
                Data = "offer"
            },
            TestContext.Current.CancellationToken).AsTask());
        Assert.Contains("37", exception.Message, StringComparison.Ordinal);
    }

    private sealed class Recorder : INotifier
    {
        internal List<Signal> Signals { get; } = [];
        public bool NotifySignal(Signal signal)
        {
            Signals.Add(signal);
            return true;
        }
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        internal HttpRequestMessage? Request { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Request = request;
            return Task.FromResult(respond(request));
        }
    }
}
