# claude -p の構造化返答の形と、capability（表情など）の指示文。すべて純粋関数。
#
# 常駐の claude は、起動時に返答の形を1つに決める。リクエストごとに欲しい capability が違っても
# 同じプロセスを使えるように、プロセスの形（for_process）は、登録されている capability すべての項目を
# 「あってもなくてもよい」形で持つ。実際に付けるかどうかは、毎ターンの指示文（brief）で伝える。
#
# 契約:
# - for_turn: capabilities が空なら base をそのまま返す。空でなければ、その項目を properties と required に足す
# - for_process: base の required は変えない。capabilities の項目は properties に足すだけ（required に入れない）
# - brief: wanted の指示文（prompt_segment）を並べ、wanted でない capability（all のうち）の項目は付けないと伝える。
#   all が空なら nil
# - どれも、引数を書き換えず、同じ入力には同じ出力を返す
module ReplySchema
  module_function

  def fields_of(capabilities)
    capabilities.reduce({}) { |fields, capability| fields.merge(capability.reply_schema) }
  end

  def for_turn(base:, capabilities:)
    return base if capabilities.empty?

    extra = fields_of(capabilities)
    base.merge(properties: base[:properties].merge(extra), required: base[:required] + extra.keys.map(&:to_s))
  end

  def for_process(base:, capabilities:)
    return base if capabilities.empty?

    base.merge(properties: base[:properties].merge(fields_of(capabilities)))
  end

  def brief(wanted:, all:)
    return nil if all.empty?

    unwanted = all.reject { |capability| wanted.include?(capability) }
    lines = wanted.map(&:prompt_segment).map(&:to_s).reject(&:empty?)
    lines << "今回の返答には、#{unwanted.map(&:name).join("、")} の項目は付けない。" unless unwanted.empty?
    lines.join("\n\n")
  end
end
