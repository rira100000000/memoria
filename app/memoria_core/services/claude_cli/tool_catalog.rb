module ClaudeCli
  # 経路（platform）ごとのツールの一覧を、1本の常駐 claude のための1つの一覧にまとめる。すべて純粋関数。
  # MCP のツール一覧は起動時に固定されるので、すべての経路のツールを和集合で持ち、
  # 呼び出されたときに、いまの経路で使えるかを確かめる。
  #
  # 契約:
  # - merge: tools は、名前の重複を除いた和集合（最初に現れた定義を使う。順序は入力の順）。
  #   platforms は、ツール名 => そのツールを持つ経路の配列
  # - available?: そのツール名を持つ経路に platform が含まれるときだけ true。知らないツール名は false
  # - 引数を書き換えない
  module ToolCatalog
    module_function

    # @param by_platform [Hash{Symbol,nil => Array<Hash>}] 経路 => ツール定義（:name を持つ Hash）の配列
    # @return [Hash] { tools: Array<Hash>, platforms: Hash{String => Array} }
    def merge(by_platform)
      tools = {}
      platforms = {}
      by_platform.each do |platform, list|
        list.each do |tool|
          name = tool[:name].to_s
          tools[name] ||= tool
          (platforms[name] ||= []) << platform
        end
      end
      { tools: tools.values, platforms: platforms }
    end

    def available?(platforms, name, platform)
      Array(platforms[name.to_s]).include?(platform)
    end
  end
end
