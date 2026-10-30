require "rails_helper"

RSpec.describe MemoriaServer::DiscordBotAuth do
  it "鍵が一致するときだけ通す" do
    expect(described_class.authorized?("Bearer secret-1", "secret-1")).to be(true)
    expect(described_class.authorized?("bearer secret-1", "secret-1")).to be(true)
    expect(described_class.authorized?("Bearer secret-2", "secret-1")).to be(false)
  end

  it "期待する鍵が未設定（nil・空）なら、何を送っても通さない" do
    expect(described_class.authorized?("Bearer ", nil)).to be(false)
    expect(described_class.authorized?("Bearer x", "")).to be(false)
    expect(described_class.authorized?("Bearer x", "  ")).to be(false)
    expect(described_class.authorized?(nil, nil)).to be(false)
  end

  it "ヘッダがない・形が違うものは通さない" do
    expect(described_class.authorized?(nil, "k")).to be(false)
    expect(described_class.authorized?("k", "k")).to be(false)
    expect(described_class.authorized?("Basic k", "k")).to be(false)
  end

  describe MemoriaServer::DiscordBotToken do
    it "環境変数の値を優先し、なければファイルから読む。どちらもなければ nil" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "token")
        File.write(path, "from-file\n")

        expect(described_class.current({ "MEMORIA_BOT_TOKEN" => "from-env", "MEMORIA_BOT_TOKEN_FILE" => path })).to eq("from-env")
        expect(described_class.current({ "MEMORIA_BOT_TOKEN_FILE" => path })).to eq("from-file")
        expect(described_class.current({ "MEMORIA_BOT_TOKEN_FILE" => File.join(dir, "none") })).to be_nil
        expect(described_class.current({})).to be_nil
      end
    end
  end
end
