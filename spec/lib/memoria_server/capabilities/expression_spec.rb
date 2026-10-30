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
    expect(capability.parse_value(expression: { face: "surprise", emote: "none" })).to eq(face: "surprise", emote: "none")
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

RSpec.describe MemoriaServer::Capabilities::Expression, "per-device vocabulary" do
  let(:expression) { described_class }
  let(:capability) { MemoriaServer::Capability.find(:expression) }
  let(:small_device) { { "expression" => { "faces" => %w[joy sadness], "emotes" => %w[goodbye-wave] } } }

  describe ".normalize_registration" do
    it "keeps only known IDs, drops duplicates, and always starts the faces with neutral" do
      result = expression.normalize_registration("faces" => %w[joy joy nonsense sadness], "emotes" => %w[goodbye-wave bogus goodbye-wave])

      expect(result).to eq(faces: %w[neutral joy sadness], emotes: %w[goodbye-wave])
    end

    it "accepts symbol keys, and an empty emote list (a device without emotes)" do
      expect(expression.normalize_registration(faces: [ "joy" ], emotes: [])).to eq(faces: %w[neutral joy], emotes: [])
    end

    it "returns nil when the registration is not a Hash" do
      [ nil, "joy", [ "joy" ], 1 ].each { |raw| expect(expression.normalize_registration(raw)).to be_nil }
    end

    it "does not change its argument" do
      raw = { "faces" => %w[joy], "emotes" => %w[bogus] }

      expect { expression.normalize_registration(raw) }.not_to(change { Marshal.dump(raw) })
    end
  end

  describe ".unknown_ids" do
    it "returns the IDs that the registration lost" do
      expect(expression.unknown_ids("faces" => %w[joy x], "emotes" => %w[y])).to eq(faces: %w[x], emotes: %w[y])
      expect(expression.unknown_ids(nil)).to eq(faces: [], emotes: [])
    end
  end

  describe ".vocabulary_for" do
    it "is the whole standard vocabulary for a device that has not registered" do
      [ nil, {}, { "other" => 1 }, { "expression" => "bad" } ].each do |caps|
        expect(expression.vocabulary_for(caps)).to eq(expression::STANDARD_VOCABULARY)
      end
    end

    it "is the registered vocabulary for a device that has" do
      expect(expression.vocabulary_for(small_device)).to eq(faces: %w[neutral joy sadness], emotes: %w[goodbye-wave])
      expect(expression.vocabulary_for(expression: { faces: [ "joy" ], emotes: [] })).to eq(faces: %w[neutral joy], emotes: [])
    end
  end

  describe ".prompt_for" do
    it "writes only the IDs the device can show" do
      text = expression.prompt_for(expression.vocabulary_for(small_device))

      expect(text).to include("- joy:", "- sadness:", "- goodbye-wave:")
      expect(text).not_to include("- anger:", "joy-clap", "pilot-joy-burst")
    end

    it "says that emotes cannot be used when the device has none" do
      text = expression.prompt_for(faces: %w[neutral], emotes: [])

      expect(text).to include("演出（エモート）は使えません")
      expect(text).not_to include("- none:")
    end

    it "is the standard prompt for the standard vocabulary" do
      expect(expression.prompt_for(expression::STANDARD_VOCABULARY)).to eq(expression::PROMPT)
    end
  end

  describe ".extract with a vocabulary" do
    let(:vocab) { expression.vocabulary_for(small_device) }

    it "drops a face the device cannot show, and turns an emote it cannot play into none" do
      expect(expression.extract({ "expression" => { "face" => "anger", "emote" => "none" } }, vocab)).to be_nil
      expect(expression.extract({ "expression" => { "face" => "joy", "emote" => "joy-clap" } }, vocab)).to eq(face: "joy", emote: "none")
      expect(expression.extract({ "expression" => { "face" => "joy", "emote" => "goodbye-wave" } }, vocab)).to eq(face: "joy", emote: "goodbye-wave")
    end
  end

  describe "through the capability" do
    it "builds the instruction and reads the value by the device's registration" do
      expect(capability.prompt_segment_for(small_device)).not_to include("anger")
      expect(capability.prompt_segment_for(nil)).to eq(described_class::PROMPT)
      expect(capability.parse_value({ "expression" => { "face" => "anger", "emote" => "none" } }, small_device)).to be_nil
      expect(capability.parse_value({ "expression" => { "face" => "anger", "emote" => "none" } })).to eq(face: "anger", emote: "none")
    end
  end
end
