defmodule BotArmyLlm.SafetyClassifier do
  @moduledoc """
  Safety classifier to prevent sensitive data routing to cloud LLM providers.

  Detects patterns that indicate sensitive data:
  - API keys (AWS, Anthropic, OpenAI, etc.)
  - Cryptographic keys (SSH, PGP, private keys)
  - Credentials (passwords, tokens, auth headers)
  - Personal identifiers (email patterns, phone numbers)
  - Financial data (credit cards, bank accounts)
  - Internal infrastructure (database URLs, private IPs)

  Classification results guide routing:
  - `contains_sensitive` → Use local Ollama only (never cloud)
  - `unknown` → Use normal routing (local→cloud chain)
  - `safe` → Proceed with normal routing

  This is a defense-in-depth layer. It's not foolproof (no classifier is),
  but it catches common accidental leaks and provides an audit trail.
  """

  require Logger

  @type classification :: :safe | :unknown | :contains_sensitive

  @doc """
  Classify text for sensitive content.

  Returns one of:
  - `:safe` — No sensitive patterns detected
  - `:unknown` — Ambiguous patterns, route conservatively (local only)
  - `:contains_sensitive` — Definite sensitive data detected, local only
  """
  @spec classify(String.t()) :: classification
  def classify(text) when is_binary(text) do
    # Run checks in order of confidence (high-confidence first)
    case detect_high_confidence_secrets(text) do
      true ->
        Logger.warning("Safety: HIGH_CONFIDENCE sensitive data detected")
        :contains_sensitive

      false ->
        case detect_medium_confidence_secrets(text) do
          true ->
            Logger.info("Safety: MEDIUM_CONFIDENCE sensitive pattern, restricting to local")
            :unknown

          false ->
            :safe
        end
    end
  end

  @doc """
  Determine if text can safely go to cloud providers.

  Use this in routing logic:
  ```
  if SafetyClassifier.safe_for_cloud?(text) do
    try_cloud_providers(text)
  else
    use_local_only(text)
  end
  ```
  """
  @spec safe_for_cloud?(String.t()) :: boolean
  def safe_for_cloud?(text) do
    classify(text) == :safe
  end

  @doc """
  Get a human-readable reason for why text was classified as sensitive.
  Returns nil for safe text.
  """
  @spec reason(String.t()) :: String.t() | nil
  def reason(text) when is_binary(text) do
    case classify(text) do
      :safe ->
        nil

      :unknown ->
        "Potentially sensitive content detected (ambiguous pattern). Local processing only."

      :contains_sensitive ->
        "Sensitive content detected (high confidence). Local processing only."
    end
  end

  # ============================================================================
  # High-Confidence Pattern Detection
  # ============================================================================
  # These patterns indicate sensitive data with very low false positive rate.

  defp detect_high_confidence_secrets(text) do
    text_lower = String.downcase(text)

    detect_api_keys(text_lower) ||
      detect_crypto_keys(text_lower) ||
      detect_credentials(text_lower) ||
      detect_financial_data(text)
  end

  # API Key patterns (very specific to major providers)
  defp detect_api_keys(text_lower) do
    # AWS: AKIA followed by 16 alphanumeric chars
    String.match?(text_lower, ~r/akia[0-9a-z]{16}/i) ||
      # Anthropic: claude-key- or sk-ant-
      String.match?(text_lower, ~r/(claude-key-|sk-ant-)[a-z0-9]+/i) ||
      # OpenAI: sk-proj- or sk- followed by reasonable key length
      String.match?(text_lower, ~r/sk-(proj-|[a-z0-9])[a-z0-9]{15,}/i) ||
      # Google Cloud: AIzaSy...
      String.match?(text_lower, ~r/aizasy[a-z0-9_-]{20,}/i) ||
      # GitHub: ghp_ or github_pat_
      String.match?(text_lower, ~r/(ghp_|github_pat_)[a-z0-9_]+/i) ||
      # Explicit secret key markers
      String.match?(text_lower, ~r/secret[_-]?key\s*[:=]\s*['"a-z0-9]{10,}/i)
  end

  # Cryptographic key patterns
  defp detect_crypto_keys(text_lower) do
    # PEM format: "-----BEGIN PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----", etc.
    String.contains?(text_lower, [
      "-----begin private key-----",
      "-----begin rsa private key-----",
      "-----begin openssh private key-----",
      "-----begin dsa private key-----",
      "-----begin ec private key-----",
      "-----begin pgp private key block-----"
    ]) ||
      # Explicit private key declarations
      String.match?(text_lower, ~r/private[_-]?key\s*[:=]\s*['"]/i) ||
      # Hex-encoded 256-bit keys (common for crypto)
      String.match?(text_lower, ~r/[0-9a-f]{64}(?:\s|,|$)/i)
  end

  # Credential and token patterns
  defp detect_credentials(text_lower) do
    # Explicit credential patterns
    String.match?(text_lower, ~r/password\s*[:=]\s*['"a-z0-9]/i) ||
      String.match?(text_lower, ~r/token\s*[:=]\s*['"a-z0-9]/i) ||
      String.match?(text_lower, ~r/bearer\s+[a-z0-9._-]{20,}/i) ||
      # JWT tokens (eyJ... base64 format)
      String.match?(text_lower, ~r/eyj[a-z0-9_-]{20,}\.[a-z0-9_-]{20,}\.[a-z0-9_-]{20,}/i) ||
      # OAuth tokens
      String.match?(text_lower, ~r/oauth[_-]?token\s*[:=]/i) ||
      # Session tokens
      String.match?(text_lower, ~r/session[_-]?(id|token)\s*[:=]/i)
  end

  # Financial and payment data
  defp detect_financial_data(text) do
    # Credit card patterns (16 digits, Luhn check not implemented for simplicity)
    String.match?(text, ~r/\b(?:\d{4}[-\s]?){3}\d{4}\b/) ||
      # Bank account patterns
      String.match?(text, ~r/account[_-]?number\s*[:=]/i) ||
      String.match?(text, ~r/routing[_-]?number\s*[:=]/i) ||
      # Stripe API keys: sk_live_ or pk_live_
      String.match?(text, ~r/(sk_live_|pk_live_)[a-z0-9]{20,}/i)
  end

  # ============================================================================
  # Medium-Confidence Pattern Detection
  # ============================================================================
  # These patterns might indicate sensitive data but have higher false positive rate.
  # Trigger conservative routing (local only) to be safe.

  defp detect_medium_confidence_secrets(text) do
    text_lower = String.downcase(text)

    detect_internal_infrastructure(text_lower) ||
      detect_personal_identifiers(text_lower) ||
      detect_explicit_secret_markers(text_lower)
  end

  # Internal infrastructure patterns
  defp detect_internal_infrastructure(text_lower) do
    # Database URLs
    String.match?(text_lower, ~r/(postgres|mysql|mongodb):\/\/[a-z0-9:@.-]+/) ||
      # Private IP addresses (10.x.x.x, 172.16.x.x, 192.168.x.x)
      String.match?(text_lower, ~r/(?:10|172(?:\.(?:1[6-9]|2\d|3[01]))?|192\.168)(?:\.\d{1,3}){2}/) ||
      # Localhost variations
      String.match?(text_lower, ~r/localhost:[0-9]{4,5}/) ||
      # SSH connection strings
      String.match?(text_lower, ~r/ssh\s*-[^-]*\s+\w+@[^:\/\s]+/) ||
      # Docker secrets format
      String.match?(text_lower, ~r/\/run\/secrets\/[a-z_-]+/i)
  end

  # Personal identifiers
  defp detect_personal_identifiers(text_lower) do
    # Email with obvious personal/internal patterns
    String.match?(text_lower, ~r/\b[a-z0-9._%+-]+@(internal|corp|private|localhost)[a-z0-9.-]*\b/) ||
      # Social security number pattern (XXX-XX-XXXX)
      String.match?(text_lower, ~r/\b\d{3}-\d{2}-\d{4}\b/) ||
      # Phone number with international prefix or extension
      String.match?(text_lower, ~r/\+\d{1,3}\s?\(?\d{3,4}\)?[\s.-]?\d{3,4}[\s.-]?\d{4,5}/) ||
      # Passport/ID number patterns
      String.match?(text_lower, ~r/passport\s*[:=]|id[_-]?number\s*[:=]/i)
  end

  # Explicit secret markers (even if value is redacted or obfuscated)
  defp detect_explicit_secret_markers(text_lower) do
    # Look for patterns like "secret_key =", "api_key:", etc with = or : nearby
    # OR just the presence of these sensitive keywords as standalone words
    String.match?(text_lower, ~r/(secret|api_?key|private_?key|encryption_?key|auth_?token|access_?token|refresh_?token|bearer_?token|client_?secret)\s*[:=]/i) ||
      (String.contains?(text_lower, " secret ") and String.length(text_lower) < 200)
  end

  # ============================================================================
  # Logging and Audit
  # ============================================================================

  @doc """
  Audit log for classification decisions. Use this when routing decisions are made.

  Example:
    text = get_prompt(...)
    case SafetyClassifier.classify(text) do
      :safe ->
        SafetyClassifier.log_decision(:safe, "routing to cloud")
        call_cloud_provider(text)
      :contains_sensitive ->
        SafetyClassifier.log_decision(:contains_sensitive, "using local only")
        call_local_ollama(text)
    end
  """
  def log_decision(classification, action) do
    Logger.info("SafetyClassifier: #{classification} → #{action}")
  end
end
