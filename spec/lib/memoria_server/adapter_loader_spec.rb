require "rails_helper"

RSpec.describe MemoriaServer, "adapter loader" do
  before do
    # adapter キャッシュをクリア
    MemoriaServer.instance_variable_set(:@adapter, nil)
  end

  after do
    MemoriaServer.instance_variable_set(:@adapter, nil)
  end

  it "defaults to MemoriaCore when MS_ADAPTER is unset" do
    ENV.delete("MS_ADAPTER")
    expect(MemoriaServer.adapter).to be_a(MemoriaServer::Adapters::MemoriaCore)
  end

  it "accepts MS_ADAPTER=memoria_core" do
    ENV["MS_ADAPTER"] = "memoria_core"
    expect(MemoriaServer.adapter).to be_a(MemoriaServer::Adapters::MemoriaCore)
    ENV.delete("MS_ADAPTER")
  end

  it "raises when MS_ADAPTER=http but no MS_ADAPTER_URL" do
    ENV["MS_ADAPTER"] = "http"
    ENV.delete("MS_ADAPTER_URL")
    expect { MemoriaServer.adapter }.to raise_error(MemoriaServer::Error, /MS_ADAPTER_URL/)
    ENV.delete("MS_ADAPTER")
  end

  it "loads HTTP adapter when MS_ADAPTER=http and URL set" do
    ENV["MS_ADAPTER"] = "http"
    ENV["MS_ADAPTER_URL"] = "http://localhost:9999"
    expect(MemoriaServer.adapter).to be_a(MemoriaServer::Adapters::Http)
    ENV.delete("MS_ADAPTER")
    ENV.delete("MS_ADAPTER_URL")
  end

  it "raises on unknown MS_ADAPTER" do
    ENV["MS_ADAPTER"] = "NoSuchAdapter"
    expect { MemoriaServer.adapter }.to raise_error(MemoriaServer::Error, /Unknown MS_ADAPTER/)
    ENV.delete("MS_ADAPTER")
  end

  it "rejects MS_ADAPTER pointing at non-adapter class" do
    ENV["MS_ADAPTER"] = "String"
    expect { MemoriaServer.adapter }.to raise_error(MemoriaServer::ContractViolation)
    ENV.delete("MS_ADAPTER")
  end

  it "allows runtime override via adapter=" do
    custom = Class.new(MemoriaServer::Adapter) do
      def respond(input, context:)
        Enumerator.new { |y| y << { done: true } }
      end
    end.new
    MemoriaServer.adapter = custom
    expect(MemoriaServer.adapter).to eq(custom)
  end

  it "rejects adapter= with non-Adapter object" do
    expect { MemoriaServer.adapter = "not an adapter" }.to raise_error(MemoriaServer::ContractViolation)
  end
end
