using System.Net;

namespace NetherNet.Discovery;

public sealed record DiscoveryOptions
{
    public ulong NetworkId { get; init; }
    public IPEndPoint? BroadcastEndpoint { get; init; }
    public int MaximumDiscoveredServers { get; init; } = 1024;
}
