jieba = require 'nodejieba'
redis = require 'redis'
emojiStrip = require 'emoji-strip'
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
				telegram.sendMessage msg.chat.id, jieba.tag(exp.substring 0,100).join(', '), msg.message_id
		,
			cmd: 'learn'
			num: -1
			desc: 'Learn a Chinese expression in a raw way.'
			act: (msg, exp) ->
				times = if typeof exp[0] == "number" then Math.max exp.shift(), 15 else 3
				return if exp.length < 1
				( learn msg, emojiStrip e if e.length <= 100 and e != '' ) for e in exp.split /[\n。！？]/ for _learn_p in [0..times-1]
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
		,
			cmd: 'answer'
			num: -1
			desc: 'Answer to the question, trying to use the given vocabulary.'
			act: (msg, args) ->
				korubaku (ko) =>
					# If the message is a reply, use the original and omit the args.
					question = msg.reply_to_message?.text || args.join ' '

					if question = question.trim() is ''
						return

					[err, model] = yield randmember "chn#{msg.chat.id}models", ko.raw()
					if !model?
						learn msg, question if 
						return

					console.log "model = #{model}"
					words = jieba.cut question
					sentence = ''
					for m in model.split ' '
						if isCustomTag m
							word = customUntag m
						else
							word = ''
							for i in [1...words.length]
								w = words[rand words.length]
								[err, word] = yield randmember "chn#{msg.chat.id}#{m}coexist#{w}", ko.raw()
								if !err? and word? and word isnt ''
									break

							console.log "#{m} -> #{word}"
							if err? or !word? or word is ''
								console.log "falling back on #{m}"
								[err, word] = yield randmember "chn#{msg.chat.id}word#{m}", ko.raw()

							if err? or !word? or word is ''
								word = "[#{tag}]"
						sentence += word
					telegram.sendMessage msg.chat.id, sentence, msg.reply_to_message?.message_id || msg.message_id
						
	]

learn = (msg, exp) ->
	console.log exp
	korubaku (ko) =>
		exp = exp.replace /^([[(<].*? ?[\])>] )+/g, ''
		exp = exp.replace /(?![^<]*>|[^<>]*<\/)(([a-z][0-9a-z]*:)\/\/[a-z0-9&#=.\/\-?_]+)/gi, ''
		exp = exp.replace /^(\S+, ?)*\S+: /, ''
		exp = exp.trim()
		console.log "exp = #{exp}"
		result = jieba.tag exp
		tags = []
		words = []
		unrecognized = 0
		for r in result
			[w..., tag] = r.split(':')
			word = w.join ':'
			
			if word.match /^\s+$/ is null
				continue
			
			tag = customTag word, tag
			tags.push tag
			words.push word

			if tag is 'eng' or tag is 'x' or tag is 'm'
				unrecognized += 1

		if unrecognized >= result.length * 0.6
			console.log 'Not accepted because of too much unrecognized string.'
			return
			
		for word, i in words
			tag = tags[i]
			console.log "#{i}: #{word} -> #{tag}"
			yield db.lpush "chn#{msg.chat.id}word#{tag}", word, ko.default()

			for w, j in words
				yield db.lpush "chn#{msg.chat.id}#{tags[j]}coexist#{word}", w, ko.default()
		
		model = tags.join ' '
		# Trys to minimize consecutive 'low-quality' chars.
		model = model.replace /(x ){2,}x/g, 'x'
		model = model.replace /(eng ){2,}eng/g ,'eng'
		console.log "Model: #{model}"
		yield db.lpush "chn#{msg.chat.id}models", model, ko.default()
			

exports.default = (msg) ->
	(learn msg, emojiStrip exp if exp.length <= 100 and exp != '') for exp in msg.text.split /[\n。！？]/

# scope start
startTags = [
	'{', '[', '(', '（', '《'
	'【', '「', '｢', '『', '‘', '“'
]

# scope end
endTags = [
	'}', ']', ')', '）', '》'
	'】', '」', '｣', '』', '’', '”'
]

# balanced tags
balTags = [ '`', "'", '"' ]
# literals
litTags = [ ',', '.', '?', '!', '.', '…', ';', '，', '；' ]

customTag = (word, tag) ->
	if tag is 'x' # We process only x
		if word in startTags
			'_my_start'
		else if word in endTags
			'_my_end'
		else if word in balTags
			'_my_bal'
		else if word in litTags
			'_my_lit_' + word
		else
			tag
	else
		tag

isCustomTag = (tag) ->
	tag.startsWith '_my'

_tagType = 3
tagType = _tagType
balType = 2
customUntag = (tag) ->
	if tag is '_my_start'
		if tagType is -1
			tagType = rand startTags.length
		startTags[tagType]
	else if tag is '_my_end'
		type = if tagType is -1 then 3 else tagType
		tagType = _tagType
		endTags[type]
	else if tag is '_my_bal'
		balTags[balType]
	else if tag.startsWith '_my_lit_'
		tag.substr 8
	else
		"[#{tag}]"

rand = (max) ->
	Math.floor Math.random() * max

randmember = (listName, callback) ->
	korubaku (ko) =>
		len = yield db.llen listName, ko.default()
		index = rand len
		[err, [member]] = yield db.lrange listName, index, index, ko.raw()
		callback err, member
