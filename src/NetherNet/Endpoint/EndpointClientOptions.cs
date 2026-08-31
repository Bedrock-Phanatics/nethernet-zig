namespace NetherNet.Endpoint;

public sealed record EndpointClientOptions
{
    public HttpClient? HttpClient { get; init; }
    public Func<CancellationToken, ValueTask<Credentials?>>? CredentialsProvider { get; init; }
    public string? NetworkId { get; init; }
}
