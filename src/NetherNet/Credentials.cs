namespace NetherNet;

public sealed record Credentials
{
    public int ExpirationInSeconds { get; init; }
    public IReadOnlyList<IceServer> IceServers { get; init; } = [];
}
