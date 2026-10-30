require "rails_helper"

RSpec.describe MemoriaServer::DeviceCapabilities do
  let(:registration) { { "expression" => { "faces" => %w[joy bogus], "emotes" => %w[goodbye-wave] } } }

  it "registers the expression of a device, narrowed to the standard vocabulary" do
    result = described_class.register({}, registration)

    expect(result.capabilities).to eq("expression" => { "faces" => %w[neutral joy], "emotes" => %w[goodbye-wave] })
    expect(result.errors).to be_empty
  end

  it "tells the device which IDs it lost" do
    result = described_class.register({}, registration)

    expect(result.dropped).to eq("expression" => { faces: %w[bogus], emotes: [] })
  end

  it "keeps the other capabilities that are already registered" do
    result = described_class.register({ "other" => { "a" => 1 } }, registration)

    expect(result.capabilities).to include("other" => { "a" => 1 }, "expression" => anything)
  end

  it "ignores keys it does not accept, and names them" do
    result = described_class.register({}, registration.merge("secret" => 1, "x" => 2))

    expect(result.capabilities.keys).to eq(%w[expression])
    expect(result.ignored).to eq(%w[secret x])
  end

  it "does not update, and says why, when expression is not an object" do
    result = described_class.register({ "expression" => { "faces" => %w[neutral], "emotes" => [] } }, "expression" => "joy")

    expect(result.errors.keys).to eq(%w[expression])
    expect(result.capabilities).to eq("expression" => { "faces" => %w[neutral], "emotes" => [] })
  end

  it "does nothing for an empty or missing registration" do
    expect(described_class.register({ "a" => 1 }, nil).capabilities).to eq("a" => 1)
    expect(described_class.register(nil, {}).capabilities).to eq({})
  end

  it "gives the same result when repeated (idempotent), and does not change its arguments" do
    existing = {}
    first = described_class.register(existing, registration)
    second = described_class.register(first.capabilities, registration)

    expect(second.capabilities).to eq(first.capabilities)
    expect(existing).to eq({})
  end

  it "accepts symbol keys" do
    result = described_class.register({}, expression: { faces: [ "joy" ], emotes: [] })

    expect(result.capabilities).to eq("expression" => { "faces" => %w[neutral joy], "emotes" => [] })
  end
end
