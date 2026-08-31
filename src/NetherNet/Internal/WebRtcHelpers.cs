using System.Text;
using System.Text.Json;
using SIPSorcery.Net;

namespace NetherNet.Internal;

internal static class WebRtcHelpers
{
    internal static RTCConfiguration CreateConfiguration(Credentials? credentials)
    {
        var iceServers = credentials?.IceServers
            .SelectMany(server => server.Urls.Select(url => new RTCIceServer
            {
                urls = url,
                username = server.Username,
                credential = server.Password,
                credentialType = RTCIceCredentialType.password
            }))
            .ToList() ?? [];

        return new RTCConfiguration
        {
            X_ICEIncludeAllInterfaceAddresses = true,
            iceServers = iceServers
        };
    }

    internal static async Task WaitForGatheringAsync(
        RTCPeerConnection peer,
        CancellationToken cancellationToken)
    {
        if (peer.iceGatheringState == RTCIceGatheringState.complete)
        {
            return;
        }

        var completion = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);

        void HandleStateChanged(RTCIceGatheringState state)
        {
            if (state == RTCIceGatheringState.complete)
            {
                completion.TrySetResult();
            }
        }

        peer.onicegatheringstatechange += HandleStateChanged;
        try
        {
            // Avoid missing a transition that occurred while the event handler was being registered.
            if (peer.iceGatheringState == RTCIceGatheringState.complete)
            {
                completion.TrySetResult();
            }
            await completion.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            peer.onicegatheringstatechange -= HandleStateChanged;
        }
    }

    internal static string AddIdentity(
        string sdp,
        Identity identity,
        RTCDtlsFingerprint fingerprint)
    {
        var identityData = identity.CreateAssertion(
            [new DtlsFingerprint(fingerprint.algorithm, fingerprint.value)]);
        var assertionJson = JsonSerializer.Serialize(new Dictionary<string, string>
        {
            ["fingerprints"] = identityData.Assertion.Fingerprints,
            ["token"] = identityData.Assertion.Token
        });
        var identityJson = JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["assertion"] = assertionJson,
            ["idp"] = new Dictionary<string, string>
            {
                ["domain"] = identityData.Provider.Domain,
                ["protocol"] = identityData.Provider.Protocol
            }
        });
        var attribute = string.Concat(
            "a=identity:",
            Convert.ToBase64String(Encoding.UTF8.GetBytes(identityJson)),
            "\r\n");
        var mediaSection = sdp.IndexOf("m=", StringComparison.Ordinal);

        return mediaSection < 0
            ? sdp + attribute
            : sdp.Insert(mediaSection, attribute);
    }

    internal static (IdentityData Data, ECDsa PublicKey)? ReadIdentity(
        string sdp,
        bool verifyToken)
    {
        const string prefix = "a=identity:";
        var identityLine = GetSdpLines(sdp)
            .FirstOrDefault(line => line.StartsWith(prefix, StringComparison.Ordinal));
        if (identityLine is null)
        {
            return null;
        }

        using var document = JsonDocument.Parse(
            Convert.FromBase64String(identityLine[prefix.Length..]));
        var root = document.RootElement;
        using var assertionDocument = JsonDocument.Parse(
            root.GetProperty("assertion").GetString() ??
            throw new JsonException("Identity assertion is missing."));
        var assertionRoot = assertionDocument.RootElement;
        var providerRoot = root.GetProperty("idp");
        var data = new IdentityData(
            new IdentityAssertion(
                assertionRoot.GetProperty("fingerprints").GetString() ??
                    throw new JsonException("Identity fingerprints are missing."),
                assertionRoot.GetProperty("token").GetString() ??
                    throw new JsonException("Identity token is missing.")),
            new IdentityProvider(
                providerRoot.GetProperty("domain").GetString() ??
                    throw new JsonException("Identity provider domain is missing."),
                providerRoot.GetProperty("protocol").GetString() ??
                    throw new JsonException("Identity provider protocol is missing.")));
        if (!data.IsValid)
        {
            throw new CryptographicException("Malformed SDP identity assertion.");
        }

        var publicKey = Identity.ClaimPublicKey(data.Assertion.Token, verifyToken);
        try
        {
            data.Verify(ReadFingerprints(sdp), publicKey);
            return (data, publicKey);
        }
        catch
        {
            publicKey.Dispose();
            throw;
        }
    }

    internal static RTCDataChannelInit ReliableChannel => new()
    {
        ordered = true
    };

    internal static RTCDataChannelInit UnreliableChannel => new()
    {
        ordered = false,
        maxRetransmits = 0
    };

    internal static DtlsFingerprint[] ReadFingerprints(string sdp)
    {
        return GetSdpLines(sdp)
            .Where(line => line.StartsWith("a=fingerprint:", StringComparison.Ordinal))
            .Select(line => line[14..].Split(' ', 2))
            .Where(parts => parts.Length == 2)
            .Select(parts => new DtlsFingerprint(parts[0], parts[1]))
            .Distinct()
            .ToArray();
    }

    private static string[] GetSdpLines(string sdp)
    {
        return sdp.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries);
    }
}
