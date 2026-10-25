using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using PopGuy.Core.Secrets;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Security.Credentials;

// Not PopGuy.Platform.System: that namespace would hide System for every System.-qualified name under PopGuy.Platform.
namespace PopGuy.Platform.SystemServices;

/// <summary>
/// Secrets in Windows Credential Manager (macOS <c>KeychainManager</c>): generic credentials whose target name is the
/// <see cref="SecretIds"/> id, user name <c>apiKey</c>, the secret as a UTF-8 blob of at most
/// <see cref="MaxSecretBytes"/> bytes, persisted for this user on this machine (not roamed).
/// <c>cmdkey /list:PopGuy/*</c> lists them. Credential Manager compares target names case-insensitively.
/// <para>
/// Errors are <see cref="Win32Exception"/> with the Win32 code only, or <see cref="ArgumentException"/>; none carries
/// key text. The managed and native buffers are zeroed after use; the returned string itself cannot be.
/// </para>
/// </summary>
public sealed class CredentialStore : ISecretStore
{
    /// <summary>CRED_MAX_CREDENTIAL_BLOB_SIZE (5*512).</summary>
    public const int MaxSecretBytes = (int)PInvoke.CRED_MAX_CREDENTIAL_BLOB_SIZE;

    private const string UserName = "apiKey";

    public unsafe string? Get(string id)
    {
        Validate(id);
        if (!PInvoke.CredRead(id, CRED_TYPE.CRED_TYPE_GENERIC, out var credential))
        {
            var error = Marshal.GetLastPInvokeError();
            if (error == (int)WIN32_ERROR.ERROR_NOT_FOUND) return null;
            throw new Win32Exception(error);
        }
        try
        {
            var blob = new Span<byte>(credential->CredentialBlob, (int)credential->CredentialBlobSize);
            var secret = Encoding.UTF8.GetString(blob);
            CryptographicOperations.ZeroMemory(blob);
            return secret;
        }
        finally
        {
            PInvoke.CredFree(credential);
        }
    }

    public unsafe void Set(string id, string secret)
    {
        Validate(id);
        ArgumentNullException.ThrowIfNull(secret);
        var size = Encoding.UTF8.GetByteCount(secret);
        if (size > MaxSecretBytes)
            throw new ArgumentException($"The API key is longer than {MaxSecretBytes} bytes.", nameof(secret));

        // Pinned, so the GC never leaves a copy of the secret behind before it is zeroed.
        var blob = GC.AllocateUninitializedArray<byte>(size, pinned: true);
        try
        {
            Encoding.UTF8.GetBytes(secret, blob);
            fixed (char* targetName = id)
            fixed (char* userName = UserName)
            fixed (byte* data = blob)
            {
                var credential = new CREDENTIALW
                {
                    Type = CRED_TYPE.CRED_TYPE_GENERIC,
                    TargetName = new PWSTR(targetName),
                    UserName = new PWSTR(userName),
                    CredentialBlob = data,
                    CredentialBlobSize = (uint)size,
                    Persist = CRED_PERSIST.CRED_PERSIST_LOCAL_MACHINE,
                };
                if (!PInvoke.CredWrite(credential, 0)) throw new Win32Exception(Marshal.GetLastPInvokeError());
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(blob);
        }
    }

    public bool Delete(string id)
    {
        Validate(id);
        if (PInvoke.CredDelete(id, CRED_TYPE.CRED_TYPE_GENERIC)) return true;
        var error = Marshal.GetLastPInvokeError();
        if (error == (int)WIN32_ERROR.ERROR_NOT_FOUND) return false;
        throw new Win32Exception(error);
    }

    /// <summary>An empty id, an embedded null (it would cut the target name short) or an over-long one is refused.</summary>
    private static void Validate(string id)
    {
        ArgumentException.ThrowIfNullOrEmpty(id);
        if (id.Contains('\0') || id.Length > PInvoke.CRED_MAX_GENERIC_TARGET_NAME_LENGTH)
            throw new ArgumentException("The secret id contains a null character or is too long.", nameof(id));
    }
}
