jieba = require 'nodejieba'
redis = require 'redis'
{korubaku} = require 'korubaku'

db = redis.createClient()

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
		,
			cmd: 'learn'
			num: 1
			desc: 'Learn a Chinese expression'
			act: (msg, exp) ->
				learn msg, exp
		,
			cmd: 'speak'
			num: 0
			desc: 'Speak a sentence based on previously learnt language model'
			act: (msg) ->
				korubaku (ko) =>
					[err, model] = yield randmember "chn#{msg.chat.id}models", ko.raw()
					if model?
						console.log "model = #{model}"
						sentence = ''
						for m in model.split(' ')
							if isCustomTag m
								word = customUntag m
							else
								[err, word] = yield randmember "chn#{msg.chat.id}word#{m}", ko.raw()
							console.log "word for #{m}: #{word}"
							sentence += word if word?
						telegram.sendMessage msg.chat.id, sentence.trim()
	]

learn = (msg, exp) ->
	korubaku (ko) =>
		exp = exp.replace /(\[|\()(.*?)(\]|\)) /g, ''
		exp = exp.replace /(?![^<]*>|[^<>]*<\/)((https?:)\/\/[a-z0-9&#=.\/\-?_]+)/gi, ''
		exp = exp.trim()
		console.log "exp = #{exp}"
		result = jieba.tag exp
		tags = []
		words = []
		unrecognized = 0
		for r in result
			[word, ..., tag] = r.split(':')
			tag = customTag word, tag
			tags.push tag
			words.push word

			if tag is 'eng' or tag is 'x'
				unrecognized += 1

		if unrecognized < result.length * 0.6
			for word, i in words
				tag = tags[i]
				console.log "#{i}: #{word} -> #{tag}"
				yield db.lpush "chn#{msg.chat.id}word#{tag}", word, ko.default()
			model = tags.join ' '
			console.log "Model: #{model}"
			yield db.lpush "chn#{msg.chat.id}models", model, ko.default()
		else
			console.log 'Not accepted because of too much unrecognized string.'

exports.default = (msg) ->
	(learn msg, exp if exp.length <= 100) for exp in msg.text.split '\n'

startTags = [
	'{', '[', '(', '\'', '"',
	'【', '「', '｢', '『', '‘', '“', '（'
]

endTags = [
	'}', ']', ')', '\'', '"',
	'】', '」', '｣', '』', '’', '”', '）'
]

customTag = (word, tag) ->
	if tag is 'x' # We process only x
		if word in startTags
			'_my_start'
		else if word in endTags
			'_my_end'
		else
			tag
	else
		tag

isCustomTag = (tag) ->
	tag.startsWith '_my'

tagType = -1

customUntag = (tag) ->
	if tag is '_my_start'
		if tagType is -1
			tagType = rand startTags.length
		startTags[tagType]
	else if tag is '_my_end'
		type = if tagType is -1
			3 # As a default
		else
			tagType
		tagType = -1
		endTags[type]
	else
		null

rand = (max) ->
	Math.floor Math.random() * max

randmember = (listName, callback) ->
	korubaku (ko) =>
		len = yield db.llen listName, ko.default()
		index = rand len
		[err, [member]] = yield db.lrange listName, index, index, ko.raw()
		callback err, member
