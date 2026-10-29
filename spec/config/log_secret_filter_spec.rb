require "rails_helper"

RSpec.describe LogSecretFilter do
  let(:key) { "AQ.Zz9dummyKeyValue_notARealSecret0123456789abcdefgh" }

  it "masks the key in a URL query" do
    text = "status 402 for POST https://example.test/v1/models/m:embed?key=#{key}"

    expect(described_class.mask(text)).to eq("status 402 for POST https://example.test/v1/models/m:embed?key=[FILTERED]")
    expect(described_class.mask("https://x.test/?a=1&key=#{key}&b=2")).to eq("https://x.test/?a=1&key=[FILTERED]&b=2")
  end

  it "masks device keys, bearer tokens and Google API keys" do
    secret = "msdk_#{'a1B2' * 8}"
    expect(described_class.mask("device #{secret} ok")).to eq("device [FILTERED] ok")
    expect(described_class.mask("Authorization: Bearer #{secret}")).to eq("Authorization: Bearer [FILTERED]")
    expect(described_class.mask("k=AIza#{'x' * 35}")).to eq("k=[FILTERED]")
  end

  it "leaves ordinary text alone" do
    text = "[ChatSession] claude -p failed: key=short and monkey=banana but not a secret"

    expect(described_class.mask(text)).to eq(text)
  end

  describe LogSecretFilter::Formatter do
    it "masks before the base formatter writes the line" do
      line = described_class.new.call("WARN", Time.now, nil, "failed: https://x.test/?key=#{key}")

      expect(line).to eq("failed: https://x.test/?key=[FILTERED]\n")
    end

    it "formats a non-string message and masks it too" do
      line = described_class.new.call("INFO", Time.now, nil, StandardError.new("bad ?key=#{key}"))

      expect(line).not_to include(key)
      expect(line).to include("[FILTERED]")
    end

    it "is what the application logs through" do
      expect(Rails.application.config.log_formatter).to be_a(described_class)
    end

    it "works under tagged logging" do
      io = StringIO.new
      logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(io))
      logger.formatter = described_class.new.tap { |f| f.extend(ActiveSupport::TaggedLogging::Formatter) }

      logger.tagged("Job") { logger.info("url ?key=#{key}") }

      expect(io.string).to eq("[Job] url ?key=[FILTERED]\n")
    end
  end
end
