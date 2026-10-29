require "rails_helper"

RSpec.describe MemoriaServer::Capabilities::Expression do
  let(:capability) { MemoriaServer::Capability.find(:expression) }

  it "is registered and returns its value with the reply" do
    expect(capability).to be_present
    expect(capability.reply_schema).to have_key(:expression)
  end

  it "reads a valid face and emote" do
    expect(capability.parse_value("expression" => { "face" => "happiness", "emote" => "gratitude-bow" }))
      .to eq(face: "happiness", emote: "gratitude-bow")
  end

  it "accepts symbol keys" do
    expect(capability.parse_value(expression: { face: "shy", emote: "none" })).to eq(face: "shy", emote: "none")
  end

  it "makes an unknown or missing emote 'none'" do
    expect(capability.parse_value("expression" => { "face" => "joy", "emote" => "dance" })[:emote]).to eq("none")
    expect(capability.parse_value("expression" => { "face" => "joy" })[:emote]).to eq("none")
  end

  it "returns nil for an unknown face or a non-object" do
    expect(capability.parse_value("expression" => { "face" => "grin" })).to be_nil
    expect(capability.parse_value("expression" => "joy")).to be_nil
    expect(capability.parse_value("reply" => "x")).to be_nil
    expect(capability.parse_value(nil)).to be_nil
  end

  it "lists every face and emote in the schema enums and the prompt" do
    schema = capability.reply_schema[:expression][:properties]
    expect(schema[:face][:enum]).to match_array(described_class::FACES.keys)
    expect(schema[:emote][:enum]).to match_array(described_class::EMOTES.keys + [ "none" ])
    (described_class::FACES.keys + described_class::EMOTES.keys).each { |id| expect(capability.prompt_segment).to include(id) }
  end
end
