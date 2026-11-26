defmodule Opsmaru.Containers.TestSupport.TLSFixture do
  @moduledoc """
  Test-generated P-256 CA and leaf certificates for loopback TLS fixtures.
  Nothing here touches a real service; files live under a private temporary
  directory the caller removes.
  """

  def root do
    root = Path.join(System.tmp_dir!(), "occ-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root
  end

  @doc "Generate a CA and a leaf for `hostname`, valid for server and client auth."
  def generate(root, name \\ "fixture", hostname \\ "localhost") do
    file = &Path.join(root, name <> &1)
    certfile = file.(".pem")
    keyfile = file.(".key")
    cafile = file.("-ca.pem")
    cakey = file.("-ca.key")
    csr = file.(".csr")
    extensions = file.(".extensions")
    configuration = file.(".configuration")

    File.write!(
      configuration,
      "[req]\ndistinguished_name=dn\n[dn]\n[ca]\nbasicConstraints=critical,CA:TRUE\n" <>
        "keyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n"
    )

    curve = ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256"]
    curve = curve ++ ["-pkeyopt", "ec_param_enc:named_curve", "-nodes"]

    openssl!(
      ["req", "-sha256", "-x509"] ++
        curve ++
        ["-days", "1", "-subj", "/CN=#{name}-fixture-ca", "-config", configuration] ++
        ["-extensions", "ca", "-keyout", cakey, "-out", cafile]
    )

    openssl!(
      ["req", "-sha256", "-new"] ++
        curve ++
        ["-subj", "/CN=#{hostname}", "-config", configuration, "-keyout", keyfile, "-out", csr]
    )

    File.write!(
      extensions,
      "subjectAltName=DNS:#{hostname}\nbasicConstraints=critical,CA:FALSE\n" <>
        "extendedKeyUsage=serverAuth,clientAuth\n"
    )

    openssl!(
      ["x509", "-sha256", "-req", "-in", csr, "-CA", cafile, "-CAkey", cakey] ++
        ["-set_serial", "1", "-days", "1", "-extfile", extensions, "-out", certfile]
    )

    for path <- [certfile, keyfile, cafile, cakey, csr, extensions, configuration],
        do: File.chmod!(path, 0o600)

    [der] = certificates(certfile)
    %{certfile: certfile, keyfile: keyfile, cafile: cafile, der: der}
  end

  def certificates(path) do
    path
    |> File.read!()
    |> :public_key.pem_decode()
    |> Enum.map(fn {:Certificate, der, _} -> der end)
  end

  defp openssl!(args) do
    {output, status} = System.cmd("openssl", args, stderr_to_stdout: true)
    if status != 0, do: raise("fixture certificate generation failed: #{output}")
  end
end
