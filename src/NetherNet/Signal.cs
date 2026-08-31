using System.Globalization;

namespace NetherNet;

public static class SignalTypes
{
    public const string Offer = "CONNECTREQUEST";
    public const string Answer = "CONNECTRESPONSE";
    public const string Candidate = "CANDIDATEADD";
    public const string Error = "CONNECTERROR";
}

public sealed record Signal
{
    public required string Type { get; init; }
    public required ulong ConnectionId { get; init; }
    public string Data { get; init; } = string.Empty;
    public string NetworkId { get; init; } = string.Empty;

    public override string ToString() => $"{Type} {ConnectionId.ToString(CultureInfo.InvariantCulture)} {Data}";

    public static Signal Parse(ReadOnlySpan<char> text)
    {
        var first = text.IndexOf(' ');
        var second = first < 0 ? -1 : text[(first + 1)..].IndexOf(' ');
        if (first < 0 || second < 0)
        {
            throw new FormatException("A signal must contain type, connection ID, and data segments.");
        }

        second += first + 1;
        if (!ulong.TryParse(text[(first + 1)..second], NumberStyles.None, CultureInfo.InvariantCulture, out var id))
        {
            throw new FormatException("The signal connection ID is not a UInt64.");
        }

        return new Signal { Type = text[..first].ToString(), ConnectionId = id, Data = text[(second + 1)..].ToString() };
    }
}
