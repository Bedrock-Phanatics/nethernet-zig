using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace NetherNet.Internal;

internal sealed record DtlsFingerprint(string Algorithm, string Value);

internal sealed record IdentityData(
    [property: JsonPropertyName("assertion")] IdentityAssertion Assertion,
    [property: JsonPropertyName("idp")] IdentityProvider Provider)
{
    internal bool IsValid =>
        Assertion.Token.Count(character => character == '.') == 2 &&
        Assertion.Fingerprints.Count(character => character == '.') == 2 &&
        Provider.Protocol == "default" &&
        Provider.Domain.Length > 0;

    internal void Verify(IReadOnlyList<DtlsFingerprint> fingerprints, ECDsa publicKey)
    {
        try
        {
            _ = Jose.JWT.VerifyBytes(
                Assertion.Fingerprints,
                publicKey,
                Jose.JwsAlgorithm.ES384,
                payload: Identity.CreateFingerprintPayload(fingerprints));
        }
        catch (Jose.JoseException exception)
        {
            throw new CryptographicException(
                "DTLS fingerprint identity assertion verification failed.",
                exception);
        }
    }
}

[JsonConverter(typeof(IdentityAssertionConverter))]
internal sealed record IdentityAssertion(
    [property: JsonPropertyName("fingerprints")] string Fingerprints,
    [property: JsonPropertyName("token")] string Token);

internal sealed record IdentityProvider(
    [property: JsonPropertyName("domain")] string Domain,
    [property: JsonPropertyName("protocol")] string Protocol);

internal sealed class IdentityAssertionConverter : JsonConverter<IdentityAssertion>
{
    public override IdentityAssertion Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options)
    {
        using var document = JsonDocument.Parse(
            reader.GetString() ?? throw new JsonException());
        return new IdentityAssertion(
            document.RootElement.GetProperty("fingerprints").GetString() ??
                throw new JsonException(),
            document.RootElement.GetProperty("token").GetString() ??
                throw new JsonException());
    }

    public override void Write(
        Utf8JsonWriter writer,
        IdentityAssertion value,
        JsonSerializerOptions options)
    {
        using var stream = new MemoryStream();
        using (var nested = new Utf8JsonWriter(stream))
        {
            nested.WriteStartObject();
            nested.WriteString("fingerprints", value.Fingerprints);
            nested.WriteString("token", value.Token);
            nested.WriteEndObject();
        }
        writer.WriteStringValue(Encoding.UTF8.GetString(stream.ToArray()));
    }
}
