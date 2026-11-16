import AgentsCore

extension ComponentDraft {
  init(_ value: ComponentDeclaration) {
    self.init()
    kind = value.kind
    switch value {
    case .skills(let source, let declaration):
      self.source = source
      skills = declaration
      agents = declaration.agents
      condition = declaration.condition
      native = declaration.native
    case .instructions(let declaration):
      instructions = declaration
      agents = declaration.agents
      condition = declaration.condition
      native = declaration.native
    case .mcpServer(let name, let transport, let agents, let condition, let native):
      self.name = name
      self.transport = transport
      self.agents = agents
      self.condition = condition
      self.native = native
    case .hook(
      let name, let event, let run, let matcher, let timeout, let agents, let condition, let native):
      self.name = name
      self.event = event
      self.run = run
      self.matcher = matcher
      self.timeout = timeout
      self.agents = agents
      self.condition = condition
      self.native = native
    case .subagent(
      let name, let description, let prompt, let model, let tools, let agents, let condition,
      let native):
      self.name = name
      self.description = description
      self.prompt = prompt
      self.model = model
      self.tools = tools
      self.agents = agents
      self.condition = condition
      self.native = native
    case .command(
      let name, let description, let prompt, let parameters, let agents, let condition, let native):
      self.name = name
      self.description = description
      self.prompt = prompt
      self.parameters = parameters
      self.agents = agents
      self.condition = condition
      self.native = native
    case .lspServer(
      let name, let run, let languages, let options, let agents, let condition, let native):
      self.name = name
      self.run = run
      self.languages = languages
      self.options = options
      self.agents = agents
      self.condition = condition
      self.native = native
    case .permissions(let name, let rules, let agents, let condition, let native):
      self.name = name
      self.rules = rules
      self.agents = agents
      self.condition = condition
      self.native = native
    case .ignore(let name, let patterns, let purpose, let agents, let condition, let native):
      self.name = name
      self.patterns = patterns
      self.purpose = purpose
      self.agents = agents
      self.condition = condition
      self.native = native
    case .plugin(
      let name, let path, let source, let mode, let select, let exclude, let agents, let condition,
      let native):
      self.name = name
      self.path = path
      self.source = source
      pluginMode = mode
      pluginSelection = select
      pluginExclusions = exclude
      self.agents = agents
      self.condition = condition
      self.native = native
    }
  }
}
