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
        # Medium confidence checks - have higher false positive rate but catch common patterns
        case detect_medium_confidence_secrets(text) do
          true ->
            Logger.debug("Safety: MEDIUM_CONFIDENCE potentially sensitive data detected")
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
    # Only return true for :safe classification
    # Both :unknown and :contains_sensitive block cloud routing
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
    # Anthropic: claude-key- or sk-ant-
    # OpenAI: sk-proj- or sk- followed by reasonable key length
    # Google Cloud: AIzaSy...
    # GitHub: ghp_ or github_pat_
    # Explicit secret/api key markers - api_key high confidence only if value looks like a real key
    String.match?(text_lower, ~r/akia[0-9a-z]{16}/i) ||
      String.match?(text_lower, ~r/(claude-key-|sk-ant-)[a-z0-9]+/i) ||
      String.match?(text_lower, ~r/sk-(proj-|[a-z0-9])[a-z0-9]{15,}/i) ||
      String.match?(text_lower, ~r/aizasy[a-z0-9_-]{20,}/i) ||
      String.match?(text_lower, ~r/(ghp_|github_pat_)[a-z0-9_]+/i) ||
      String.match?(text_lower, ~r/secret[_-]?key\s*[:=]\s*['"a-z0-9]{3,}/i) ||
      String.match?(text_lower, ~r/api[_-]?key\s*[:=]\s*['"][a-z0-9]+['"]/i)
  end

  # Cryptographic key patterns
  defp detect_crypto_keys(text_lower) do
    # PEM format: "-----BEGIN PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----", etc.
    # Only high-confidence for actual PEM blocks, not just variable declarations
    # Hex-encoded 256-bit keys (common for crypto) - allow quotes or delimiters
    # Explicit private_key assignments with values (quoted or unquoted)
    String.contains?(text_lower, [
      "-----begin private key-----",
      "-----begin rsa private key-----",
      "-----begin openssh private key-----",
      "-----begin dsa private key-----",
      "-----begin ec private key-----",
      "-----begin pgp private key block-----"
    ]) ||
      String.match?(text_lower, ~r/[0-9a-f]{64}(?:\s|,|'|"|$)/i) ||
      String.match?(text_lower, ~r/private[_-]?key\s*[:=]\s*['"][a-z0-9]{20,}['"]/i) ||
      String.match?(text_lower, ~r/private[_-]?key\s*[:=]\s+[a-z0-9]{6,}/i)
  end

  # Credential and token patterns
  defp detect_credentials(text_lower) do
    # Explicit credential patterns
    # Use negative lookbehind to avoid matching prefixed versions (e.g., bearer_token)
    # which should be caught by medium-confidence detector instead
    # JWT tokens (eyJ... base64 format)
    # OAuth tokens
    # Session tokens
    String.match?(text_lower, ~r/(?<![a-z_-])password\s*[:=]\s*['"a-z0-9]/i) ||
      String.match?(text_lower, ~r/(?<![a-z_-])token\s*[:=]\s*['"a-z0-9]/i) ||
      String.match?(text_lower, ~r/bearer\s+[a-z0-9._-]{20,}/i) ||
      String.match?(text_lower, ~r/eyj[a-z0-9_-]{20,}\.[a-z0-9_-]{20,}\.[a-z0-9_-]{20,}/i) ||
      String.match?(text_lower, ~r/oauth[_-]?token\s*[:=]/i) ||
      String.match?(text_lower, ~r/session[_-]?(id|token)\s*[:=]/i)
  end

  # Financial and payment data
  defp detect_financial_data(text) do
    # Credit card patterns (16 digits, Luhn check not implemented for simplicity)
    # Bank account patterns
    # Stripe API keys: sk_live_ or pk_live_
    String.match?(text, ~r/\b(?:\d{4}[-\s]?){3}\d{4}\b/) ||
      String.match?(text, ~r/account[_-]?number\s*[:=]/i) ||
      String.match?(text, ~r/routing[_-]?number\s*[:=]/i) ||
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

    # Note: detect_personal_work_context disabled - causes false positives
    # with legitimate system documentation and LLM orchestration prompts
  end

  # Detect resume and work-related personal data
  defp detect_personal_work_context(text_lower) do
    # Flag resume/CV content and work history as personal data that should stay local
    # Flag when combined with typical job application context
    String.match?(
      text_lower,
      ~r/(resume|cv|curriculum\s+vitae|professional\s+summary|years?\s+of\s+experience|relevant\s+experience|key\s+achievements?|accomplishments?)/i
    ) ||
      (String.match?(
         text_lower,
         ~r/(job\s+title|company|employment|role|position|responsibility|achievement|bullet|skill|expertise)/i
       ) &&
         String.match?(
           text_lower,
           ~r/(worked|developed|led|managed|designed|implemented|built|created)/i
         ))
  end

  # Internal infrastructure patterns
  defp detect_internal_infrastructure(text_lower) do
    # Database URLs
    # Private IP addresses (10.x.x.x, 172.16.x.x, 192.168.x.x)
    # Localhost variations
    # SSH connection strings
    # Docker secrets format
    String.match?(text_lower, ~r/(postgres|mysql|mongodb):\/\/[a-z0-9:@.-]+/) ||
      String.match?(
        text_lower,
        ~r/(?:10|172(?:\.(?:1[6-9]|2\d|3[01]))?|192\.168)(?:\.\d{1,3}){2}/
      ) ||
      String.match?(text_lower, ~r/localhost:[0-9]{4,5}/) ||
      String.match?(text_lower, ~r/ssh\s*-[^-]*\s+\w+@[^:\/\s]+/) ||
      String.match?(text_lower, ~r/\/run\/secrets\/[a-z_-]+/i)
  end

  # Personal identifiers
  defp detect_personal_identifiers(text_lower) do
    # Email with obvious personal/internal patterns
    # Social security number pattern (XXX-XX-XXXX)
    # Phone number with international prefix or extension
    # Passport/ID number patterns
    String.match?(text_lower, ~r/\b[a-z0-9._%+-]+@(internal|corp|private|localhost)[a-z0-9.-]*\b/) ||
      String.match?(text_lower, ~r/\b\d{3}-\d{2}-\d{4}\b/) ||
      String.match?(text_lower, ~r/\+\d{1,3}\s?\(?\d{3,4}\)?[\s.-]?\d{3,4}[\s.-]?\d{4,5}/) ||
      String.match?(text_lower, ~r/passport\s*[:=]|id[_-]?number\s*[:=]/i)
  end

  # Explicit secret markers (even if value is redacted or obfuscated)
  defp detect_explicit_secret_markers(text_lower) do
    # Look for patterns like "secret_key =", "api_key:", etc with = or : nearby
    # Match with both underscore and hyphen variants
    # Bare "secret" word with assignment (at start or surrounded by spaces)
    # Bare "secret" word mentioned standalone (medium confidence)
    # Match "secret" at the start or surrounded by spaces
    String.match?(
      text_lower,
      ~r/(secret[-_]?key|api[-_]?key|private[-_]?key|encryption[-_]?key|password[-_]?field|password|auth[-_]?token|access[-_]?token|refresh[-_]?token|bearer[-_]?token|client[-_]?secret)\s*[:=]/i
    ) ||
      String.match?(text_lower, ~r/^secret\s*[:=]/i) ||
      String.match?(text_lower, ~r/\s+secret\s*[:=]/i) ||
      (String.match?(text_lower, ~r/(^|\s)secret(\s|$)/i) and String.length(text_lower) < 200)
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
