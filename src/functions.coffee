jieba = require 'nodejieba'
{korubaku} = require 'korubaku'

exports.name = 'chinese-lang'
exports.desc = 'Chinese language model'

exports.setup = (telegram, store, server, config) ->
	jieba.load()

	[
			cmd: 'struct'
			num: 1
			desc: 'Get the structure of a Chinese expression'
			act: (msg, exp) ->
				exp = exp.substring 0, 30 if exp.length > 30
				result = jieba.tag exp
				txt = ''
				txt += r.split(':')[1] + ' ' for r in result
				telegram.sendMessage msg.chat.id, txt.trim(), msg.message_id
	]
