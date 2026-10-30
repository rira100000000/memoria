require "rails_helper"

# RoutedChat の契約:
# - ツール一覧は、すべての経路のツールの和集合（起動時に固定）
# - 呼ばれたとき、route_path のファイルのいまの経路で使えるツールだけを実行する。使えなければ実行せず、error を返す
# - 経路のファイルがなくても壊れない（経路なし = API として扱う）
RSpec.describe ClaudeCli::ToolProvider::RoutedChat do
  let(:character) { create(:character) }
  let(:record) { create(:chat_session_record, character: character) }
  let(:dir) { Dir.mktmpdir }
  let(:route_path) { File.join(dir, "route.json") }
  let(:plugin_class) do
    Class.new(MemoriaServer::Plugin) do
      def name = :routed_chat_test

      def tools(scene:, platform: nil)
        return [] unless scene == :chat

        list = [ { name: "everywhere_t", description: "e", parameters: { type: "object", properties: {} } } ]
        list << { name: "discord_only_t", description: "d", parameters: { type: "object", properties: {} } } if platform == :discord
        list
      end

      def execute(tool_name, _args, character:, scene:)
        { ran: tool_name }
      end
    end
  end
  let(:provider) { described_class.new(character, record_id: record.id, route_path: route_path) }

  before { MemoriaServer::Plugin.register(plugin_class.new) }
  after { MemoriaServer::Plugin.unregister(:routed_chat_test) }

  def write_route(platform)
    File.write(route_path, ConversationRoute.dump(ConversationRoute.new(platform: platform, channel: "x")))
  end

  it "lists the tools of every route, once each" do
    names = provider.tools.map { |tool| tool[:name] }

    expect(names).to include("everywhere_t", "discord_only_t")
    expect(names.count("everywhere_t")).to eq(1)
  end

  it "runs a tool that the current route has" do
    write_route(:discord)

    expect(provider.call("discord_only_t", {})).to include(ran: "discord_only_t")
  end

  it "does not run a tool that the current route does not have" do
    write_route(nil)

    expect(provider.call("discord_only_t", {})).to eq(error: "「discord_only_t」は、いまの経路（API）では使えません")
  end

  it "follows the route file as it changes between turns" do
    write_route(nil)
    expect(provider.call("discord_only_t", {})).to have_key(:error)

    write_route(:discord)

    expect(provider.call("discord_only_t", {})).to include(ran: "discord_only_t")
  end

  it "treats a missing route file as the API route" do
    expect(provider.call("everywhere_t", {})).to include(ran: "everywhere_t")
    expect(provider.call("discord_only_t", {})).to have_key(:error)
  end

  it "treats a route outside the known ones by that route's own tools, not by refusing everything" do
    write_route(:reading)

    expect(provider.call("everywhere_t", {})).to include(ran: "everywhere_t")
    expect(provider.call("discord_only_t", {})).to have_key(:error)
  end

  it "builds a ChatSession once per route, however many tools are called" do
    write_route(:discord)
    provider
    allow(::ChatSession).to receive(:new).and_call_original

    3.times { provider.call("everywhere_t", {}) }

    expect(::ChatSession).not_to have_received(:new)
  end

  it "is built by ToolProvider.build when a route file is given, and only then" do
    routed = ClaudeCli::ToolProvider.build(character: character, scene: :chat, record_id: record.id, route_path: route_path)
    plain = ClaudeCli::ToolProvider.build(character: character, scene: :chat, platform: :discord, record_id: record.id)

    expect(routed).to be_a(described_class)
    expect(plain).to be_a(ClaudeCli::ToolProvider::Chat)
  end
end
