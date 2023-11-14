@tool
class_name EzDialogueReader extends Node

## Emitted when the end of the dialogue is reached and
## no more dialogue needs to be processed.
signal end_of_dialogue_reached()

## Emitted when the current "page" of dialogue is processed.
## [param response] includes simple [param text] response,
## and dialogue choices if applicable.
signal dialogue_generated(response: DialogueResponse)

## Emitted when the dialogue reads a command for custom signal.
## [param value] is a String value used within [param signal] dialogue command.
##
## ie. if you wrote [param signal(value1,value2,value3)], [param value] = [param "value1,value2,value3"]
signal custom_signal_received(value)

@onready var is_running = false
@onready var _resource_cache: Dictionary = {}

var _processing_dialogue: DialogueResource
var _executing_command_stack: Array[DialogueCommand]

# Actions for each choice index is stored here while
# waiting for caller response on choice selection.
var _pending_choice_actions: Array
var _stateReference: Dictionary

func _process(delta):
	if is_running:
		var response = DialogueResponse.new()
		while is_running:
			if _executing_command_stack.is_empty():
				is_running = false
				if _pending_choice_actions.is_empty():
					end_of_dialogue_reached.emit()
				break
				
			_process_command(_executing_command_stack.pop_front(), response)

		dialogue_generated.emit(response)

## Load and start processing the dialogue.
##
## [param dialogue] dialogue JSON file generated by EzDialogue plugin.
## 
## [param state] Dictionary of game state data that is accessible
## and manipulatable by the dialogue process.
##
## [param start_node] name of the dialogue node the process should begin with.
## The default starting node is [param "start"].
func start_dialogue(
	dialogue: JSON, state: Dictionary, starting_node = "start"):
	
	_load_dialogue(dialogue)
	
	_executing_command_stack = _processing_dialogue.get_node_by_name(
		starting_node).get_parse()
	_pending_choice_actions = []
	_stateReference = state
	is_running = true

func _load_dialogue(dialogue: JSON):
	if !_resource_cache.has(dialogue.resource_path):
		var dialogueResource = DialogueResource.new()
		dialogueResource.loadFromJson(dialogue.data)
		_resource_cache[dialogue.resource_path] = dialogueResource
	_processing_dialogue = _resource_cache[dialogue.resource_path]
	
## Begin processing next step/page of the dialogue.
## the call is ignored if the previous start/run of dialogue is not finished.
## Dialogue process is considered "finished" and ready to move on to next
## if [signal EzDialogue.dialogue_generated] is emited.	
## 
## [param choice_index] index number of the dialogue choice to select from
## the previous response. If the previous Dialogue resoponse doesn't require
## a choice, this parameter is ignored and the next dialogue is processed.
# Provide choice index from the response if relevant.
func next(choice_index: int = 0):
	if is_running:
		return
		
	if choice_index >= 0 && choice_index < _pending_choice_actions.size():
		# select a choice
		var commands = _pending_choice_actions[choice_index] as Array[DialogueCommand]
		commands.append_array(_executing_command_stack)
		_executing_command_stack = commands
		
		# clear pending choices for new execution
		_pending_choice_actions = []
		is_running = true
	else:
		# resume executing existing commmand stack
		is_running = true

func _process_command(command: DialogueCommand, response: DialogueResponse):
	if command.type == DialogueCommand.CommandType.ROOT:
		var front = command.children.duplicate(true)
		front.append_array(_executing_command_stack)
		_executing_command_stack = front
	elif command.type == DialogueCommand.CommandType.SIGNAL:
		var signalValue = command.values[0]
		custom_signal_received.emit(signalValue)
	elif command.type == DialogueCommand.CommandType.BRACKET:
		# push contents of bracket into execution stack
		var front = command.children.duplicate(true)
		front.append_array(_executing_command_stack)
		_executing_command_stack = front
	elif command.type == DialogueCommand.CommandType.DISPLAY_TEXT:
		var displayText: String = _inject_variable_to_text(command.values[0].strip_edges(true,true))
		# normal text display
		response.append_text(displayText)
	elif command.type == DialogueCommand.CommandType.PAGE_BREAK:
		# page break. stop processing until further user input
		is_running = false
	elif command.type == DialogueCommand.CommandType.PROMPT:
		# choice item
		var actions: Array[DialogueCommand] = []
		var prompt: String = _inject_variable_to_text(command.values[0])
		actions.append_array(command.children)
		response.append_choice(prompt)
		_pending_choice_actions.push_back(actions)
	elif command.type == DialogueCommand.CommandType.GOTO:
		# jump to and run specified node
		# NOTE: GOTO is a terminating command, meaning any remaining commands
		# in the execution stack is cleared and replaced by commands in
		# the destination node.
		var destination_node = command.values[0]
		_executing_command_stack = _processing_dialogue.get_node_by_name(
			destination_node).get_parse()
	elif command.type == DialogueCommand.CommandType.CONDITIONAL:
		var expression = command.values[0]
		var result = _evaluate_conditional_expression(expression)
		if result:
			#drop other elif and else's
			while !_executing_command_stack.is_empty() && \
				(_executing_command_stack[0].type == DialogueCommand.CommandType.ELSE || \
				_executing_command_stack[0].type == DialogueCommand.CommandType.ELIF):
				_executing_command_stack.pop_front()
			_queue_executing_commands(command.children)
	elif command.type == DialogueCommand.CommandType.ELSE:
		_queue_executing_commands(command.children)
		
func _inject_variable_to_text(text: String):
		# replacing variable placeholders
		var requiredVariables: Array[String] = []
		var variablePlaceholderRegex = RegEx.new()
		variablePlaceholderRegex.compile("\\${(\\S+?)}")
		var final_text = text
		var matchResults = variablePlaceholderRegex.search_all(final_text)
		for result in matchResults:
			requiredVariables.push_back(result.get_string(1))
		
		for variable in requiredVariables:
			var value = _stateReference.get(variable)
			if not value is String:
				value = str(value)
			final_text = final_text.replace(
				"${%s}"%variable, value)
		return final_text

func _queue_executing_commands(commands: Array[DialogueCommand]):
	var copy = commands.duplicate(true)
	copy.append_array(_executing_command_stack)
	_executing_command_stack = copy

func _evaluate_conditional_expression(expression: String):
	# initial version of conditional expression...
	# only handle order of operation and && and ||
	var properties = _stateReference.keys()
	var evaluation = Expression.new()
	var availableVariables: Array[String] = []
	var variableValues = []
	for property in properties:
		availableVariables.push_back(property)
		variableValues.push_back(_stateReference.get(property))
	
	evaluation.parse(expression, PackedStringArray(availableVariables))
	return evaluation.execute(variableValues, null, true)
