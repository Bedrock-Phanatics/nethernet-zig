namespace NetherNet;

/// <summary>
/// Describes a STUN or TURN server supplied by a signaling credentials provider.
/// </summary>
public sealed record IceServer
{
    public string Username { get; init; } = string.Empty;
    public string Password { get; init; } = string.Empty;
    public IReadOnlyList<string> Urls { get; init; } = [];
}
