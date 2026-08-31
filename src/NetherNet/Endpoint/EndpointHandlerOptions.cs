namespace NetherNet.Endpoint;

public sealed record EndpointHandlerOptions
{
    public Func<CancellationToken, ValueTask<Credentials?>>? CredentialsProvider { get; init; }
    public string? NetworkId { get; init; }
    public TimeSpan NegotiationTimeout { get; init; } = TimeSpan.FromSeconds(15);
    public int MaximumPendingOffers { get; init; } = 64;
}
