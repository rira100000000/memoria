require "rails_helper"

RSpec.describe MemoriaServer::Plugin do
  let(:character) { create(:character) }

  let(:test_plugin_class) do
    Class.new(described_class) do
      attr_reader :calls

      def name = :test_plugin_xyz

      def enabled_for?(character) = character.name != "無効"

      def tools(scene:, platform: nil)
        return [] unless scene == :chat

        [{
          name: "echo_xyz",
          description: "echo",
          parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
        }]
      end

      def execute(tool_name, args, character:, scene:)
        raise "boom" if args["text"] == "boom"

        { echoed: args["text"], scene: scene }
      end

      def prompt_segment(_character, scene:)
        "テスト用の指示（#{scene}）"
      end
    end
  end

  before { described_class.register(test_plugin_class.new) }
  after { described_class.unregister(:test_plugin_xyz) }

  describe ".register" do
    it "rejects objects that are not plugins" do
      expect { described_class.register(Object.new) }.to raise_error(MemoriaServer::ContractViolation)
    end
  end

  describe ".gemini_declarations" do
    it "converts JSON Schema types to Gemini's upper case" do
      decl = described_class.gemini_declarations(character, scene: :chat).find { |d| d[:name] == "echo_xyz" }

      expect(decl[:parameters][:type]).to eq("OBJECT")
      expect(decl[:parameters][:properties][:text][:type]).to eq("STRING")
    end

    it "only offers tools for the matching scene" do
      names = described_class.gemini_declarations(character, scene: :thinking).map { |d| d[:name] }
      expect(names).not_to include("echo_xyz")
    end

    it "skips plugins disabled for the character" do
      character.update!(name: "無効")
      names = described_class.gemini_declarations(character, scene: :chat).map { |d| d[:name] }
      expect(names).not_to include("echo_xyz")
    end
  end

  describe ".execute" do
    it "routes to the plugin that declared the tool" do
      result = described_class.execute("echo_xyz", { "text" => "hi" }, character: character, scene: :chat)
      expect(result).to eq({ echoed: "hi", scene: :chat })
    end

    it "returns nil for tools no plugin declares" do
      expect(described_class.execute("no_such_tool", {}, character: character, scene: :chat)).to be_nil
    end

    it "returns nil when the tool is not offered in that scene" do
      expect(described_class.execute("echo_xyz", { "text" => "hi" }, character: character, scene: :thinking)).to be_nil
    end

    it "turns plugin exceptions into an error result" do
      result = described_class.execute("echo_xyz", { "text" => "boom" }, character: character, scene: :chat)
      expect(result[:error]).to include("boom")
    end
  end

  describe ".prompt_segments" do
    it "joins segments from enabled plugins" do
      expect(described_class.prompt_segments(character, scene: :chat)).to include("テスト用の指示（chat）")
    end
  end

  describe ".load_paths!" do
    it "loads plugin files from the given directories" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "loaded_plugin_xyz.rb"), <<~RUBY)
          class LoadedPluginXyz < MemoriaServer::Plugin
            def name = :loaded_plugin_xyz
          end
          MemoriaServer::Plugin.register(LoadedPluginXyz.new)
        RUBY

        described_class.load_paths!(dir)

        expect(described_class.find(:loaded_plugin_xyz)).to be_present
      ensure
        described_class.unregister(:loaded_plugin_xyz)
      end
    end

    it "keeps going when a plugin file is broken" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "broken.rb"), "class Broken <")

        expect { described_class.load_paths!(dir) }.not_to raise_error
      end
    end
  end

  describe "#wake" do
    it "wakes the character now to report in its own words" do
      wakeup = test_plugin_class.new.wake(character, purpose: "作業の結果を伝える")

      expect(wakeup.action).to eq("share")
      expect(wakeup.remember).to be false
      expect(ThinkingLoopJob).to have_been_enqueued.with(character.id, wakeup.id, wakeup.scheduled_at.to_i)
    end
  end

  describe MemoriaServer::Plugins::Schedule do
    subject(:plugin) { described_class.new }

    it "offers approval only in Discord chat" do
      chat = plugin.tools(scene: :chat, platform: :discord).map { |t| t[:name] }
      thinking = plugin.tools(scene: :thinking).map { |t| t[:name] }

      expect(chat).to include("approve_schedule")
      expect(thinking).to include("add_schedule")
      expect(thinking).not_to include("approve_schedule")
    end

    it "offers nothing in chats outside Discord" do
      expect(plugin.tools(scene: :chat, platform: nil)).to eq([])
    end

    it "treats the thinking loop as autonomous" do
      plugin.execute("add_schedule", { "repeat" => "0 22 * * *", "purpose" => "日記" },
        character: create(:character), scene: :thinking)

      expect(ScheduledWakeup.last.status).to eq("proposed")
    end
  end
end
