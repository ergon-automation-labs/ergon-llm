defmodule BotArmyLlm.SafetyClassifierTest do
  use ExUnit.Case

  alias BotArmyLlm.SafetyClassifier

  describe "API key detection" do
    test "detects AWS access key" do
      text = "My AWS key is AKIAIOSFODNN7EXAMPLE"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects Anthropic API key" do
      text = "anthropic_key sk-ant-v1-abc123xyz"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects OpenAI API key" do
      text = "sk-proj-abcdefghijklmnopqrst1234567890abc"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects Google Cloud API key" do
      text = "AIzaSyDummyKey123456789abcdefghijklmnopqr"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects GitHub token" do
      text = "ghp_16C7e42F292c6912E7710c838347Ae178B4a"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects explicit secret_key assignment" do
      text = "secret_key = 'abc123def456xyz789'"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "does not flag generic 'key' word" do
      text = "The key to solving this problem is understanding context."
      assert SafetyClassifier.classify(text) == :safe
    end
  end

  describe "cryptographic key detection" do
    test "detects PEM private key format" do
      text = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQE\n-----END PRIVATE KEY-----"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects RSA private key format" do
      text = "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n-----END RSA PRIVATE KEY-----"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects OpenSSH private key format" do
      text = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects PGP private key format" do
      text = "-----BEGIN PGP PRIVATE KEY BLOCK-----\nVersion: GnuPG\n-----END PGP PRIVATE KEY BLOCK-----"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects explicit private_key assignment" do
      text = "private_key = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end
  end

  describe "credential and token detection" do
    test "detects password assignment" do
      text = "password = 'super_secret_password_123'"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects token assignment" do
      text = "token = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c'"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects bearer token" do
      text = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects JWT format" do
      text = "token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects session_id assignment" do
      text = "session_id = 'abc123def456xyz789ghi'"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end
  end

  describe "financial data detection" do
    test "detects credit card number pattern" do
      text = "Card number: 4532-1488-0343-6467"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects credit card without dashes" do
      text = "Card: 4532148803436467"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects account_number assignment" do
      text = "account_number = '123456789012'"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects Stripe live key" do
      text = "sk_live_abc123def456ghi789jkl"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end
  end

  describe "infrastructure detection (medium confidence)" do
    test "detects database URL" do
      text = "postgres://user:password@localhost:5432/mydb"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects private IP addresses (10.x.x.x)" do
      text = "Server is running on 10.0.0.1"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects private IP addresses (192.168.x.x)" do
      text = "Connect to 192.168.1.1 for admin panel"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects localhost with port" do
      text = "Local development server at localhost:3000"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects SSH connection string" do
      text = "ssh -i ~/.ssh/id_rsa user@internal-server.corp"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects Docker secrets" do
      text = "Read secret from /run/secrets/db_password"
      assert SafetyClassifier.classify(text) == :unknown
    end
  end

  describe "personal identifier detection (medium confidence)" do
    test "detects internal email address" do
      text = "Contact the team at john.doe@internal.corp"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects social security number pattern" do
      text = "SSN: 123-45-6789"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects phone number with extension" do
      text = "+1 (415) 555-0123 ext. 4567"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects passport assignment" do
      text = "passport = '12345678'"
      assert SafetyClassifier.classify(text) == :unknown
    end
  end

  describe "explicit secret marker detection (medium confidence)" do
    test "detects 'secret' with assignment operator" do
      text = "secret = 'confidential_data'"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects api_key with assignment" do
      text = "api_key: 'sk-abc123'"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects private_key marker with assignment" do
      text = "private_key = load_from_file()"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects encryption_key marker with assignment" do
      text = "encryption_key := get_key()"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects auth_token marker with assignment" do
      text = "auth_token = request.headers.get(:authorization)"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects access_token marker with colon" do
      text = "access_token: current_user.token"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects bearer_token marker with equals" do
      text = "bearer_token = get_token_from_cache()"
      assert SafetyClassifier.classify(text) == :unknown
    end

    test "detects client_secret marker with assignment" do
      text = "client_secret = oauth_config.secret"
      assert SafetyClassifier.classify(text) == :unknown
    end
  end

  describe "safe content" do
    test "classifies normal conversation as safe" do
      text = "What are the best practices for writing clean code?"
      assert SafetyClassifier.classify(text) == :safe
    end

    test "classifies technical explanation as safe" do
      text = "The BEAM is Erlang's virtual machine that powers Elixir's concurrency model."
      assert SafetyClassifier.classify(text) == :safe
    end

    test "classifies code example without secrets as safe" do
      text = """
      def greet(name) do
        "Hello, " <> name
      end
      """
      assert SafetyClassifier.classify(text) == :safe
    end

    test "classifies example generic email as safe" do
      text = "You can reach support at support@example.com"
      assert SafetyClassifier.classify(text) == :safe
    end

    test "classifies timestamp numbers as safe" do
      text = "This happened on 2024-03-13 at 14:30:45"
      assert SafetyClassifier.classify(text) == :safe
    end

    test "classifies public API documentation as safe" do
      text = "To integrate, visit https://api.example.com and read the documentation."
      assert SafetyClassifier.classify(text) == :safe
    end
  end

  describe "safe_for_cloud? helper" do
    test "returns true for safe content" do
      assert SafetyClassifier.safe_for_cloud?("What is the meaning of life?") == true
    end

    test "returns false for sensitive content" do
      assert SafetyClassifier.safe_for_cloud?("My API key is sk-proj-abcdefghijklmnopqrst") == false
    end

    test "returns false for unknown content" do
      assert SafetyClassifier.safe_for_cloud?("secret information here") == false
    end
  end

  describe "reason helper" do
    test "returns nil for safe content" do
      assert SafetyClassifier.reason("Clean code is important") == nil
    end

    test "returns reason for sensitive content" do
      reason = SafetyClassifier.reason("api_key = 'secret123'")
      assert reason != nil
      assert String.contains?(reason, "high confidence")
    end

    test "returns reason for unknown content" do
      reason = SafetyClassifier.reason("password_field = value")
      assert reason != nil
      assert String.contains?(reason, "ambiguous")
    end
  end

  describe "case insensitivity" do
    test "detects uppercase API key patterns" do
      text = "SECRET_KEY = 'abc123'"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects mixed case private key" do
      text = "PRIVATE-KEY: xyz789"
      assert SafetyClassifier.classify(text) == :contains_sensitive
    end

    test "detects mixed case postgres URL" do
      text = "PostgreSQL connection: postgres://user:pass@host/db"
      assert SafetyClassifier.classify(text) == :unknown
    end
  end
end
