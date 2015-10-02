jieba = require 'nodejieba'
redis = require 'redis'
emojiStrip = require 'emoji-strip'
{korubaku} = require 'korubaku'

OpenCC = require 'opencc'
opencc = new OpenCC 't2s.json'

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
			num: 1
			desc: 'Learn a Chinese expression'
			act: (msg, exp) ->
				learn msg, exp
		,
			cmd: 'great'
			num: 0
			desc: 'Did I say something correct?'
			act: (msg) ->
				learnLast msg
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
						sentence = sentence.trim()
						saveLast msg.chat.id, sentence
						telegram.sendMessage msg.chat.id, sentence
		,
			cmd: 'answer'
			num: -1
			desc: 'Answer to the question'
			act: (msg, args) ->
				korubaku (ko) =>
					question = args.join ' '

					# If the message is a reply, use the original
					if question.trim() is '' and msg.reply_to_message?
						question = msg.reply_to_message.text

					question = filter question
					question = yield opencc.convert question, ko.default()

					if question.trim() is ''
						return

					[err, model] = yield randmember "chn#{msg.chat.id}models", ko.raw()
					if !model?
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
									continue
						sentence += word
					sentence = sentence.trim()
					saveLast msg.chat.id, sentence
					telegram.sendMessage msg.chat.id, sentence,
						if !msg.reply_to_message?
							msg.message_id
						else
							msg.reply_to_message.message_id
	]

saveLast = (chat, exp) ->
	korubaku (ko) =>
		yield db.hset "chn#{chat}", 'last', exp, ko.default()
		yield db.hset "chn#{chat}", 'lastTime', Date.now(), ko.default()

learnLast = (msg) ->
	korubaku (ko) =>
		[err, last] = yield db.hget "chn#{msg.chat.id}", 'last', ko.raw()
		[err, lastTime] = yield db.hget "chn#{msg.chat.id}", 'lastTime', ko.raw()
		if !err? and last? and last isnt '' and Date.now() - lastTime < 10000
			console.log "last = #{last}"
			yield db.hset "chn#{msg.chat.id}", 'last', '', ko.default()
			learn msg, last

# Consider these keywords as appreciations
appreciations = [
	'233', 'woc', '卧槽',
	'成精', '666'
]

isAppreciation = (exp) ->
	appreciations.some (a) ->
		~exp.indexOf a

filter = (exp) ->
	exp = exp.replace /^([[(<].*? ?[\])>] )+/g, ''
	exp = exp.replace /(?![^<]*>|[^<>]*<\/)(([a-z][0-9a-z]*:)\/\/[a-z0-9&#=.\/\-?_]+)/gi, ''
	exp = exp.replace /^(\S+, ?)*\S+: /, ''
	exp = exp.replace /((\/|\@)[a-zA-Z0-9]*) /, ''
	exp

learn = (msg, exp) ->
	console.log exp
	korubaku (ko) =>
		exp = filter exp
		exp = exp.trim()

		# Convert all to SC!
		exp = yield opencc.convert exp, ko.default()

		if isAppreciation exp
			console.log 'appreciation!'
			learnLast msg

		console.log "exp = #{exp}"
		result = jieba.tag exp
		tags = []
		words = []
		unrecognized = 0
		for r in result
			[w..., tag] = r.split(':')
			word = w.join ':'

			if word is ' '
				continue

			if tag is 'eng' or tag is 'x' or tag is 'm'
				unrecognized += 1

			tag = customTag word, tag
			tags.push tag
			words.push word

		if unrecognized >= result.length * 0.6
			console.log 'Not accepted because of too much unrecognized string.'
			return
			
		for word, i in words
			tag = tags[i]
			console.log "#{i}: #{word} -> #{tag}"
			yield addmember "chn#{msg.chat.id}word#{tag}", word, ko.default()

			for w, j in words
				yield addmember "chn#{msg.chat.id}#{tags[j]}coexist#{word}", w, ko.default()
		
		model = tags.join ' '
		# Trys to minimize consecutive 'low-quality' chars.
		model = model.replace /(x ){2,}x/g, 'x'
		model = model.replace /(eng ){2,}eng/g ,'eng'
		console.log "Model: #{model}"
		yield addmember "chn#{msg.chat.id}models", model, ko.default()
			

exports.default = (msg) ->
	(learn msg, emojiStrip exp if exp.length <= 100 and exp != '') for exp in msg.text.split /[\n|?|!|。|！|？]/

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
		null

rand = (max) ->
	Math.floor Math.random() * max

# For a sorted list in redis
weightedRandom = (len) ->
	total = (1 + len) * len / 2
	r = rand len
	t = 0
	result = 0
	for i in [1...len]
		t += i
		if t >= r
			result = i
			break
	result

addmember = (setName, member, callback) ->
	korubaku (ko) =>
		exist = yield db.exists setName, ko.default()

		if exist is 0
			console.log "set #{setName} does not exist"

		[err, score] = yield db.zscore setName, member, ko.raw()
		if score?
			score = Number score
			score += 1
		else
			score = 1
		console.log "#{member} -> #{score}"
		[err, reply] = yield db.zadd setName, score, member, ko.raw()

		if exist is 0
			console.log "adding TTL to #{setName}"
			# Keep only 2 days of data
			yield db.expire setName, 2 * 24 * 60 * 60, ko.default()

		callback err, reply

randmember = (setName, callback) ->
	korubaku (ko) =>
		[err, len] = yield db.zcard setName, ko.raw()
		index = weightedRandom len
		[err, [member]] = yield db.zrange setName, index, index, ko.raw()
		callback err, member
