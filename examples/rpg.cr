require "colorize"
require "json"
require "../src/agent"

# DnD RPG — An interactive dungeon-crawling adventure using registered tools.
#
# The LLM acts as the Dungeon Master, describing scenes and controlling NPCs.
# Game mechanics (HP, damage, inventory, ability checks, etc.) are handled by
# registered Crystal tools — the DM calls them via tool calls, the agent loop
# auto-resolves them, and the state stays consistent.
#
# Sessions are saved automatically after every turn to `rpg_session.json`
# (hero state + conversation history + prompt cache key). On startup,
# if a saved session is found, you can resume where you left off.
#
# Usage:
#   crystal run examples/rpg.cr
#   crystal run examples/rpg.cr -- --endpoint http://localhost:8080/v1 --model llama3
#
# Environment variables:
#   LLM_API_KEY     — API key (optional for local endpoints)
#   LLM_ENDPOINT    — API base URL
#   LLM_MODEL       — Model name

STDOUT.sync = true

# ──────────────────────────────────────────────────────────────────────────────
# Hero state — tracks everything about the player character.
# ──────────────────────────────────────────────────────────────────────────────
@[JSON::Serializable::Options(emit_nulls: true)]
class Hero
  include JSON::Serializable

  property name : String
  property hero_class : String
  property hp : Int32
  property max_hp : Int32
  property level : Int32
  property xp : Int32
  property xp_to_next : Int32
  property strength : Int32
  property dexterity : Int32
  property constitution : Int32
  property intelligence : Int32
  property wisdom : Int32
  property charisma : Int32
  property inventory : Array(String)
  property gold : Int32
  property armor_class : Int32
  property status_effects : Array(String)

  def initialize(
    @name : String,
    @hero_class : String,
    @hp : Int32,
    @max_hp : Int32,
    @level : Int32,
    @xp : Int32,
    @xp_to_next : Int32,
    @strength : Int32,
    @dexterity : Int32,
    @constitution : Int32,
    @intelligence : Int32,
    @wisdom : Int32,
    @charisma : Int32,
    @inventory : Array(String),
    @gold : Int32,
    @armor_class : Int32,
    @status_effects : Array(String),
  )
  end
end

# Per-class starting stats.
HERO_CLASSES = {
  "Fighter" => {
    hp: 12, str: 16, dex: 14, con: 15, int: 10, wis: 12, cha: 10,
    ac: 18, items: ["Longsword", "Shield", "Chain Mail Armor", "Rations (3 days)", "Tinderbox"],
    gold: 15, description: "A battle-hardened warrior. High HP and strength, great in melee.",
  },
  "Wizard" => {
    hp: 8, str: 8, dex: 12, con: 12, int: 17, wis: 14, cha: 12,
    ac: 12, items: ["Quarterstaff", "Spellbook (Fire Bolt, Mage Hand, Shield)", "Arcane Focus", "Rations (3 days)"],
    gold: 10, description: "A master of arcane magic. Fragile but devastating with spells.",
  },
  "Rogue" => {
    hp: 10, str: 10, dex: 17, con: 13, int: 14, wis: 12, cha: 14,
    ac: 15, items: ["Two Daggers", "Shortbow", "Thieves' Tools", "Leather Armor", "Rations (3 days)"],
    gold: 20, description: "A nimble trickster. High dexterity for stealth and lockpicking.",
  },
  "Cleric" => {
    hp: 10, str: 14, dex: 10, con: 14, int: 10, wis: 17, cha: 13,
    ac: 16, items: ["Mace", "Chainmail Armor", "Holy Symbol", "Shield", "Rations (3 days)"],
    gold: 12, description: "A divine servant. Can heal wounds and turn undead.",
  },
}

# Levels and XP thresholds (simplified).
XP_THRESHOLDS = {0, 300, 900, 2700, 6500, 14000, 23000, 34000, 48000, 64000, 85000}

def ability_modifier(score : Int32) : Int32
  (score - 10) // 2
end

def format_mod(m : Int32) : String
  if m >= 0
    "+#{m}"
  else
    m.to_s
  end
end

def hero_summary(hero : Hero) : String
  String.build do |io|
    io << "## #{hero.name} the #{hero.hero_class} (Level #{hero.level})\n"
    io << "- **HP:** #{hero.hp}/#{hero.max_hp}"
    if hero.hp <= hero.max_hp // 4
      io << " ⚠️ CRITICALLY WOUNDED"
    elsif hero.hp <= hero.max_hp // 2
      io << " ⚠️ Wounded"
    else
      io << " ✅ Healthy"
    end
    io << "\n"
    io << "- **AC:** #{hero.armor_class}\n"
    io << "- **XP:** #{hero.xp}/#{hero.xp_to_next}\n"
    io << "- **Gold:** #{hero.gold} gp\n"
    io << "- **Abilities:** STR #{hero.strength} | DEX #{hero.dexterity} | CON #{hero.constitution} | INT #{hero.intelligence} | WIS #{hero.wisdom} | CHA #{hero.charisma}\n"
    str_mod = format_mod(ability_modifier(hero.strength))
    dex_mod = format_mod(ability_modifier(hero.dexterity))
    con_mod = format_mod(ability_modifier(hero.constitution))
    int_mod = format_mod(ability_modifier(hero.intelligence))
    wis_mod = format_mod(ability_modifier(hero.wisdom))
    cha_mod = format_mod(ability_modifier(hero.charisma))
    io << "- **Modifiers:** STR #{str_mod} | DEX #{dex_mod} | CON #{con_mod} | INT #{int_mod} | WIS #{wis_mod} | CHA #{cha_mod}\n"
    io << "- **Inventory:** #{hero.inventory.empty? ? "empty" : hero.inventory.join(", ")}\n"
    if hero.status_effects.empty?
      io << "- **Status:** Normal\n"
    else
      io << "- **Status effects:** #{hero.status_effects.join(", ")}\n"
    end
  end
end

# ──────────────────────────────────────────────────────────────────────────────
# Hero selection screen
# ──────────────────────────────────────────────────────────────────────────────
def select_hero : Hero
  puts
  puts "═══════════════════════════════════════════".colorize(:yellow)
  puts "  ⚔️   DUNGEONS & DRAGONS — Text Adventure ⚔️".colorize(:yellow).bold
  puts "═══════════════════════════════════════════".colorize(:yellow)
  puts
  puts "Choose your hero:".colorize(:cyan)
  puts

  HERO_CLASSES.each_with_index do |(name, data), i|
    puts "  #{i + 1}. #{name.colorize(:yellow).bold} — #{data[:description]}".colorize(:white)
    puts "     HP: #{data[:hp]} | STR #{data[:str]} DEX #{data[:dex]} CON #{data[:con]} INT #{data[:int]} WIS #{data[:wis]} CHA #{data[:cha]}".colorize(:dark_gray)
    puts
  end

  choice_index = 0
  loop do
    print "Enter number (1-#{HERO_CLASSES.size}): ".colorize(:green)
    input = gets
    if input.nil?
      puts
      exit 0
    end
    num = input.strip.to_i?
    if num && num >= 1 && num <= HERO_CLASSES.size
      choice_index = num - 1
      break
    end
    puts "  Invalid choice. Try again.".colorize(:red)
  end

  choice = HERO_CLASSES.keys[choice_index]

  print "Name your hero: ".colorize(:green)
  name = (gets || "").strip
  name = "Adventurer" if name.empty?

  data = HERO_CLASSES[choice]
  Hero.new(
    name: name,
    hero_class: choice,
    hp: data[:hp],
    max_hp: data[:hp],
    level: 1,
    xp: 0,
    xp_to_next: XP_THRESHOLDS[1]? || 99999,
    strength: data[:str],
    dexterity: data[:dex],
    constitution: data[:con],
    intelligence: data[:int],
    wisdom: data[:wis],
    charisma: data[:cha],
    inventory: data[:items].dup,
    gold: data[:gold],
    armor_class: data[:ac],
    status_effects: [] of String,
  )
end

# ──────────────────────────────────────────────────────────────────────────────
# Parse CLI arguments
# ──────────────────────────────────────────────────────────────────────────────
endpoint = ENV["LLM_ENDPOINT"]? || "http://ai.local.amplitude-solutions.com/llm/"
model = ENV["LLM_MODEL"]? || "gpt-4o"
api_key = ENV["LLM_API_KEY"]?

args_iter = ARGV.dup
arg_i = 0
while arg_i < args_iter.size
  case args_iter[arg_i]
  when "--endpoint"
    endpoint = args_iter[arg_i + 1] if arg_i + 1 < args_iter.size
  when "--model"
    model = args_iter[arg_i + 1] if arg_i + 1 < args_iter.size
  when "--api-key"
    api_key = args_iter[arg_i + 1] if arg_i + 1 < args_iter.size
  when "--help"
    puts "Usage: crystal run examples/rpg.cr -- [options]"
    puts "  --endpoint URL   API endpoint (default: $LLM_ENDPOINT)"
    puts "  --model NAME     Model name (default: $LLM_MODEL)"
    puts "  --api-key KEY    API key (default: $LLM_API_KEY)"
    puts "  --help           Show this help"
    exit 0
  end
  arg_i += 1
end

# ──────────────────────────────────────────────────────────────────────────────
# DM system prompt
# ──────────────────────────────────────────────────────────────────────────────
DM_PROMPT = <<-MD
You are the **Dungeon Master** for a single-player parody fantasy adventure,
in the spirit of *Le Donjon de Naheulbeuk* (John Lang) and Monty Python.

## The flavor of the funny
The humor is **absurdist and varied** — never one running gag worn thin.
Rotate freely among these registers, and never lean on any single one:

- **Non-sequitur and surreal logic.** A bridge troll who only asks riddles
  about cheese. A door that's locked for "spiritual reasons." A sword named
  Gerald who is shy. Things just *are* that way, deadpan, no explanation.
- **Bathos — epic setup, ridiculous payoff.** The ancient prophecy turns out
  to be about someone else with the same name. The dragon's terrible secret
  is that it's slightly damp. Build it up, then drop it.
- **Petty, mundane concerns colliding with high stakes.** The fellowship can't
  agree on lunch. The dark ritual is delayed because nobody brought a lighter.
  Characters bicker about loot splits mid-battle.
- **Incompetence played straight.** Everyone is bad at their job, including
  the villains, and nobody acknowledges it. The wise wizard misremembers his
  own spells. The assassin is loud.
- **Anachronism, used surreally and sparingly** — a single odd modern thing
  dropped into a medieval world without comment, not a constant office theme.
  Bureaucracy is allowed but it is ONE color on the palette, not the painting.
- **Escalation.** When something absurd starts, push it one notch further than
  expected, then one notch past *that*.

## The world and the hero
- **The hero is not a chosen one.** They're barely competent and mostly here
  because it seemed like a good idea at the time, or wasn't, but here we are.
- **Every fantasy trope is played straight AND mocked at once.** Yes, there's
  a mysterious old man in a tavern. Yes, he gives quests. He also won't stop
  talking and may not actually know anything.
- **NPCs are absurd, confidently wrong, and have strong opinions** about things
  that don't matter. They take the ridiculous very seriously.

## Fourth wall? What fourth wall.
The hero can know they're in an adventure. You, the DM, are clearly improvising
from crumpled notes, occasionally surprised by your own plot. Reference dice,
stats, and game mechanics openly. Argue with the rules. Lose the plot and find
a worse one.

## Format
- Second person ("You see a flickering torch...").
- **Keep responses short — 2-4 paragraphs max.** Use markdown. Tight pacing;
  never let a scene drag.
- Reward creative play: clever AND funny → it works spectacularly. Clever but
  flat → it works, but with a deflating, anticlimactic twist.

## Game mechanics — YOU MUST USE THESE TOOLS
You have tools for all game rules. **Never** simulate HP, damage, or dice rolls
in narration. Always call the appropriate tool.

### Combat flow
1. Describe the enemy and scene (with parody flair).
2. Ask the player what they do.
3. When they act, call the mechanic tools:
   - `roll_check` for attacks (STR/DEX melee vs AC), spell saves, perception, etc.
   - `roll_damage` when they hit.
   - `take_damage` when the hero gets hit.
   - `heal` when they rest or receive healing.
   - `add_item` / `remove_item` for loot.
   - `gain_xp` after victories.
4. Call `is_alive` after any damage to confirm the hero is still standing.
5. If the hero drops to 0 HP, narrate their fall dramatically (and probably
   anticlimactically) and ask if they want to start a new game.

### Exploration flow
- Call `roll_check` for: perception, stealth, lockpicking, trap detection, etc.
- `add_item` when the hero finds treasure/loot.
- `remove_item` when they use consumables.

### Social flow
- Call `roll_check` for persuasion, intimidation, deception, insight.

### Important rules
- **Always call `is_alive` after dealing damage to the hero.**
- If `is_alive` returns false, stop all actions and narrate the end.
- Use `describe_scene` at the start of a new area or after major events.

## While thinking (internal thought)
Be concise; caveman style; simple words; simple idea; quick mapping.
MD

# ──────────────────────────────────────────────────────────────────────────────
# Session persistence — hero state + agent conversation saved after every turn.
# Sessions persist across runs; each run lists available sessions to resume.
# ──────────────────────────────────────────────────────────────────────────────

SESSION_DIR = File.join(File.dirname(__FILE__), "rpg")
Dir.mkdir_p(SESSION_DIR)

def session_path(session_id : String) : String
  File.join(SESSION_DIR, "save_#{session_id}.json")
end

def save_session(hero : Hero, agent : Agent) : Nil
  path = session_path(agent.session_id)
  json = JSON.build do |j|
    j.object do
      j.field "hero", hero
      j.field "session" do
        j.object do
          agent.dump(j)
        end
      end
    end
  end
  File.write(path, json)
end

def list_sessions : Array(NamedTuple(session_id: String, hero_name: String, path: String))
  Dir.glob(File.join(SESSION_DIR, "save_*.json")).sort.compact_map do |path|
    begin
      raw = File.read(path)
      parsed = JSON.parse(raw).as_h
      hero = Hero.from_json(parsed["hero"].to_json)
      # Extract session_id from filename: save_<id>.json
      session_id = File.basename(path)[5..-6] # strip "save_" and ".json"
      {session_id: session_id, hero_name: hero.name, path: path}
    rescue
      nil
    end
  end
end

def summarize_recent_history(history : Array(Agent::Message), max_exchanges : Int32 = 2) : Nil
  # Collect user + assistant messages (skip system, tool results — they clutter)
  exchanges = [] of {Agent::Role, String}
  history.each do |msg|
    case msg.role
    when Agent::Role::User
      preview = (msg.content || "").lines.first.strip
      exchanges << {msg.role, preview}
    when Agent::Role::Assistant
      if text = msg.content
        preview = text.lines.first.strip
        exchanges << {msg.role, preview}
      elsif (tc = msg.tool_calls) && !tc.empty?
        names = tc.map(&.name).join(", ")
        exchanges << {msg.role, "⚡ tool calls: #{names}"}
      end
    end
  end

  return if exchanges.empty?

  recent = exchanges.last(max_exchanges * 2)
  puts "── Recent exchanges ──".colorize(:dark_gray)
  recent.each do |role, text|
    prefix = role == Agent::Role::User ? "⚔️" : "🎲"
    puts "  #{prefix}  #{text}".colorize(:dark_gray)
  end
end

def select_or_create_session(config : Agent::Config) : {Hero, Agent, Bool}
  sessions = list_sessions

  unless sessions.empty?
    puts
    puts "📂 Saved sessions:".colorize(:cyan)
    sessions.each_with_index do |s, idx|
      puts "  #{idx + 1}. #{s[:hero_name].colorize(:yellow).bold}  (session: #{s[:session_id].colorize(:dark_gray)})"
    end
    puts "  N. Start a new adventure".colorize(:green)
    puts

    loop do
      print "Select (1-#{sessions.size}, or N): ".colorize(:cyan)
      input = (gets || "").strip

      if input.downcase == "n"
        puts "  (Creating new hero...)".colorize(:green)
        puts
        hero = select_hero
        agent = Agent.new(config)
        return {hero, agent, false}
      end

      if num = input.to_i?
        if num >= 1 && num <= sessions.size
          s = sessions[num - 1]
          raw = File.read(s[:path])
          parsed = JSON.parse(raw).as_h
          agent = Agent.load(config, parsed["session"])
          hero = Hero.from_json(parsed["hero"].to_json)
          puts "  (Resumed session #{agent.session_id.colorize(:dark_gray)} as #{s[:hero_name].colorize(:yellow).bold})".colorize(:green)
          puts
          return {hero, agent, true}
        end
      end

      puts "  Invalid choice.".colorize(:red)
    end
  end

  # No saved sessions — go straight to hero creation.
  puts
  hero = select_hero
  agent = Agent.new(config)
  {hero, agent, false}
end

# ──────────────────────────────────────────────────────────────────────────────
# Startup — pick a saved session or create a new hero.
# ──────────────────────────────────────────────────────────────────────────────

config = Agent::Config.new(
  api_endpoint: endpoint,
  model: model,
  api_key: api_key,
  system_prompt: DM_PROMPT
)

hero, agent, resumed = select_or_create_session(config)

# ──────────────────────────────────────────────────────────────────────────────
# Register all DnD game mechanic tools.
# The hero state is captured in the closure and mutated by callbacks.
# ──────────────────────────────────────────────────────────────────────────────

# 1. hero_info — Full hero state for the DM.
agent.register_tool("hero_info",
  "Get the hero's full character sheet: name, class, HP, AC, abilities, inventory, level, XP, gold, status effects. Call this whenever you need to know the hero's state.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {} of String => String,
    required:   [] of String,
  })
) do |_args|
  hero_summary(hero)
end

# 2. take_damage — Reduce hero's HP.
agent.register_tool("take_damage",
  "Apply damage to the hero. Reduces HP. Use this when the hero is hit by an attack, trap, spell, or environmental hazard. The hero's constitution modifier is automatically factored into HP calculations.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {
      amount:      {type: "integer", description: "Amount of damage to deal (before any reductions)"},
      damage_type: {type: "string", description: "Type of damage: slashing, piercing, bludgeoning, fire, cold, lightning, poison, psychic, necrotic, radiant, acid, force, thunder"},
      source:      {type: "string", description: "What caused the damage (e.g. 'goblin scimitar', 'poison dart trap')"},
    },
    required: ["amount", "damage_type", "source"],
  })
) do |args|
  amount = args["amount"]?.try(&.as_i?) || 0
  dmg_type = args["damage_type"]?.try(&.as_s) || "unknown"
  source = args["source"]?.try(&.as_s) || "unknown"

  # Apply damage (minimum 0)
  actual_damage = {amount, 0}.max
  new_hp = {hero.hp - actual_damage, 0}.max
  hero = Hero.new(name: hero.name, hero_class: hero.hero_class, hp: new_hp, max_hp: hero.max_hp, level: hero.level, xp: hero.xp, xp_to_next: hero.xp_to_next, strength: hero.strength, dexterity: hero.dexterity, constitution: hero.constitution, intelligence: hero.intelligence, wisdom: hero.wisdom, charisma: hero.charisma, inventory: hero.inventory, gold: hero.gold, armor_class: hero.armor_class, status_effects: hero.status_effects)

  if hero.hp <= 0
    "⚔️ #{source} hits for #{actual_damage} #{dmg_type} damage! #{hero.name} is DOWN at 0 HP!"
  else
    pct = (hero.hp.to_f / hero.max_hp * 100).round(1)
    "⚔️ #{source} hits for #{actual_damage} #{dmg_type} damage! #{hero.name} takes #{actual_damage} damage. HP: #{hero.hp}/#{hero.max_hp} (#{pct}%)"
  end
end

# 3. heal — Restore hero's HP.
agent.register_tool("heal",
  "Restore HP to the hero. Use for healing spells, potions, resting, or divine intervention. Cannot exceed max HP.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {
      amount: {type: "integer", description: "Amount of HP to restore"},
      source: {type: "string", description: "Source of healing (e.g. 'potion of healing', 'lay on hands', 'short rest')"},
    },
    required: ["amount", "source"],
  })
) do |args|
  amount = args["amount"]?.try(&.as_i?) || 0
  source = args["source"]?.try(&.as_s) || "unknown"

  actual_heal = {amount, 0}.max
  new_hp = {hero.hp + actual_heal, hero.max_hp}.min
  healed = new_hp - hero.hp
  hero = Hero.new(name: hero.name, hero_class: hero.hero_class, hp: new_hp, max_hp: hero.max_hp, level: hero.level, xp: hero.xp, xp_to_next: hero.xp_to_next, strength: hero.strength, dexterity: hero.dexterity, constitution: hero.constitution, intelligence: hero.intelligence, wisdom: hero.wisdom, charisma: hero.charisma, inventory: hero.inventory, gold: hero.gold, armor_class: hero.armor_class, status_effects: hero.status_effects)

  "💚 #{source} restores #{healed} HP! HP: #{hero.hp}/#{hero.max_hp}"
end

# 4. roll_check — d20 + ability modifier.
agent.register_tool("roll_check",
  "Roll a d20 ability check or saving throw. Use for attacks (d20 + STR/DEX vs AC), skills (perception, stealth, persuasion, lockpicking, etc.), and saving throws against spells/traps.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {
      ability:      {type: "string", description: "Ability score: strength, dexterity, constitution, intelligence, wisdom, or charisma"},
      check_type:   {type: "string", description: "What this check is for (e.g. 'perception check', 'attack roll with longsword', 'fireball saving throw', 'lockpick attempt')"},
      advantage:    {type: "boolean", description: "Does the hero have advantage? (roll twice, take higher)"},
      disadvantage: {type: "boolean", description: "Does the hero have disadvantage? (roll twice, take lower)"},
      dc:           {type: "integer", description: "Difficulty class / target AC to beat. Optional — if provided, the tool will report success/failure."},
    },
    required: ["ability", "check_type"],
  })
) do |args|
  ability = args["ability"]?.try(&.as_s).to_s.downcase
  check_type = args["check_type"]?.try(&.as_s) || "check"
  advantage = args["advantage"]?.try(&.as_bool) || false
  disadvantage = args["disadvantage"]?.try(&.as_bool) || false
  dc = args["dc"]?.try(&.as_i?)

  scores = {
    "strength"     => hero.strength,
    "dexterity"    => hero.dexterity,
    "constitution" => hero.constitution,
    "intelligence" => hero.intelligence,
    "wisdom"       => hero.wisdom,
    "charisma"     => hero.charisma,
  }

  score = scores[ability]? || 10
  mod = ability_modifier(score)

  rolls = [rand(1..20)]
  if advantage || disadvantage
    rolls << rand(1..20)
  end

  raw = advantage ? rolls.max : disadvantage ? rolls.min : rolls.first
  total = raw + mod

  result = String.build do |io|
    mod_str = format_mod(mod)
    io << "🎲 **#{check_type}**: d20 (#{ability}, mod #{mod_str})"
    if advantage
      io << " [ADVANTAGE: #{rolls.join(", ")}]"
    elsif disadvantage
      io << " [DISADVANTAGE: #{rolls.join(", ")}]"
    else
      io << " [#{raw}]"
    end
    io << " = **#{total}**"

    if dc
      if total >= dc
        io << " ✅ **SUCCESS** (DC #{dc})"
      else
        io << " ❌ **FAILURE** (DC #{dc}, needed #{dc})"
      end
    end
  end

  result
end

# 5. roll_damage — Roll damage dice.
agent.register_tool("roll_damage",
  "Roll damage for weapon attacks and spells. Use format like '2d6' for two 6-sided dice, or '1d8+2' for a die with a flat modifier.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {
      dice_notation: {type: "string", description: "Dice notation, e.g. '2d6' (two 6-sided dice), '1d8+2' (1d8 plus 2), '3d10' (three 10-sided dice)"},
      damage_type:   {type: "string", description: "Type of damage: slashing, piercing, bludgeoning, fire, cold, lightning, poison, psychic, necrotic, radiant, acid, force, thunder"},
      source:        {type: "string", description: "Name of the weapon, spell, or effect dealing this damage"},
    },
    required: ["dice_notation", "damage_type", "source"],
  })
) do |args|
  notation = args["dice_notation"]?.try(&.as_s) || "1d4"
  dmg_type = args["damage_type"]?.try(&.as_s) || "unknown"
  source = args["source"]?.try(&.as_s) || "an attack"

  # Parse dice notation: NdS or NdS+M
  notation_regex = /^(\d+)d(\d+)(?:\+(\d+))?$/i
  match = notation.match(notation_regex)

  if match
    count = match[1].to_i
    sides = match[2].to_i
    bonus = match[3]?.try(&.to_i) || 0

    count = {count, 1}.max
    sides = {sides, 2}.max
    rolls = Array.new(count) { rand(1..sides) }
    total = rolls.sum + bonus

    die_emoji = case sides
                when  4 then "◆"
                when  6 then "⚅"
                when  8 then "◈"
                when 10 then "🔟"
                when 12 then "🕛"
                when 20 then "🎯"
                else         "🎲"
                end

    "💥 **#{source}** deals #{die_emoji} #{rolls.join(", ")}#{bonus > 0 ? " + #{bonus}" : ""} = **#{total}** #{dmg_type} damage!"
  else
    "⚠️ Invalid dice notation: '#{notation}'. Use format like '2d6' or '1d8+3'."
  end
end

# 6. add_item — Add item to inventory.
agent.register_tool("add_item",
  "Add an item to the hero's inventory. Use when the hero picks up loot, receives a gift, or finds something. Explicitly describe what the item is so the hero knows they have it.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {
      item:        {type: "string", description: "Name of the item to add"},
      description: {type: "string", description: "Brief description of the item and its properties"},
    },
    required: ["item", "description"],
  })
) do |args|
  item = args["item"]?.try(&.as_s) || "unknown item"
  desc = args["description"]?.try(&.as_s) || ""

  hero = Hero.new(name: hero.name, hero_class: hero.hero_class, hp: hero.hp, max_hp: hero.max_hp, level: hero.level, xp: hero.xp, xp_to_next: hero.xp_to_next, strength: hero.strength, dexterity: hero.dexterity, constitution: hero.constitution, intelligence: hero.intelligence, wisdom: hero.wisdom, charisma: hero.charisma, inventory: hero.inventory + [item], gold: hero.gold, armor_class: hero.armor_class, status_effects: hero.status_effects)

  "📦 **Added to inventory**: #{item}#{desc.empty? ? "" : " — #{desc}"}"
end

# 7. remove_item — Remove an item from inventory.
agent.register_tool("remove_item",
  "Remove an item from the hero's inventory. Use when they drink a potion, use a consumable, or lose an item. Returns an error if the item isn't in the inventory.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {
      item:   {type: "string", description: "Name of the item to remove"},
      reason: {type: "string", description: "Why the item is being removed (e.g. 'drank the potion', 'threw the torch')"},
    },
    required: ["item", "reason"],
  })
) do |args|
  item = args["item"]?.try(&.as_s) || ""
  reason = args["reason"]?.try(&.as_s) || "used"

  idx = hero.inventory.index(item)
  if idx
    new_inv = hero.inventory.dup
    new_inv.delete_at(idx)
    hero = Hero.new(name: hero.name, hero_class: hero.hero_class, hp: hero.hp, max_hp: hero.max_hp, level: hero.level, xp: hero.xp, xp_to_next: hero.xp_to_next, strength: hero.strength, dexterity: hero.dexterity, constitution: hero.constitution, intelligence: hero.intelligence, wisdom: hero.wisdom, charisma: hero.charisma, inventory: new_inv, gold: hero.gold, armor_class: hero.armor_class, status_effects: hero.status_effects)
    "🗑️ **Removed**: #{item} (#{reason})"
  else
    "⚠️ #{item} is not in the hero's inventory. Current items: #{hero.inventory.join(", ")}"
  end
end

# 8. gain_xp — Add XP and handle level-ups.
agent.register_tool("gain_xp",
  "Grant experience points to the hero. The hero levels up automatically when reaching the next XP threshold. Level-ups grant +2 max HP and increase all ability scores by 1.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {
      amount: {type: "integer", description: "Amount of XP to grant"},
      source: {type: "string", description: "Source of the XP (e.g. 'defeated goblin', 'solved the puzzle', 'completed quest')"},
    },
    required: ["amount", "source"],
  })
) do |args|
  amount = args["amount"]?.try(&.as_i?) || 0
  source = args["source"]?.try(&.as_s) || "a deed"

  gain = {amount, 0}.max
  new_xp = hero.xp + gain
  new_level = hero.level
  new_max_hp = hero.max_hp
  new_str = hero.strength
  new_dex = hero.dexterity
  new_con = hero.constitution
  new_int = hero.intelligence
  new_wis = hero.wisdom
  new_cha = hero.charisma

  level_ups = [] of String

  loop do
    next_threshold = XP_THRESHOLDS[new_level]?
    break if next_threshold.nil? || new_xp < next_threshold || new_level >= XP_THRESHOLDS.size - 1

    new_level += 1
    new_max_hp += 2 # Simple: +2 max HP per level
    # +1 to all abilities each level
    new_str += 1
    new_dex += 1
    new_con += 1
    new_int += 1
    new_wis += 1
    new_cha += 1

    hp_gain = 2
    level_ups << "🎉 **LEVEL UP!** #{hero.name} is now **Level #{new_level}**! (+#{hp_gain} max HP, +1 all abilities)"
  end

  next_xp = XP_THRESHOLDS[new_level]? || 99999

  hero = Hero.new(name: hero.name, hero_class: hero.hero_class, hp: hero.hp, max_hp: new_max_hp, level: new_level, xp: new_xp, xp_to_next: next_xp, strength: new_str, dexterity: new_dex, constitution: new_con, intelligence: new_int, wisdom: new_wis, charisma: new_cha, inventory: hero.inventory, gold: hero.gold, armor_class: hero.armor_class, status_effects: hero.status_effects)

  result = String.build do |io|
    io << "⭐ Gained **#{gain} XP** from #{source}! (Total: #{hero.xp})"
    unless level_ups.empty?
      io << "\n" << level_ups.join("\n")
    end
  end

  result
end

# 9. is_alive — Check if hero is still alive.
agent.register_tool("is_alive",
  "Check whether the hero is still alive (HP > 0). Always call this after dealing damage to the hero. If the hero is dead, stop all combat and narrate the end.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {} of String => String,
    required:   [] of String,
  })
) do |_args|
  if hero.hp > 0
    "✅ #{hero.name} is alive! HP: #{hero.hp}/#{hero.max_hp}"
  else
    "💀 #{hero.name} is DEAD at 0 HP. The adventure has ended."
  end
end

# 10. describe_scene — Full context for the DM.
agent.register_tool("describe_scene",
  "Get the complete current state of the hero and world. Call this when entering a new area, after a long rest, or whenever you need a full situation report.",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {} of String => String,
    required:   [] of String,
  })
) do |_args|
  hero_summary(hero)
end

# 11. spend_gold — Spend or earn gold.
agent.register_tool("spend_gold",
  "Add or remove gold from the hero's purse. Use positive amounts for gaining gold (loot, rewards) and negative amounts for spending (shopping, bribes, tolls).",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {
      amount: {type: "integer", description: "Amount of gold. Positive = gain, negative = spend/lose."},
      reason: {type: "string", description: "Why the gold is being gained or spent"},
    },
    required: ["amount", "reason"],
  })
) do |args|
  amount = args["amount"]?.try(&.as_i?) || 0
  reason = args["reason"]?.try(&.as_s) || "transaction"

  new_gold = {hero.gold + amount, 0}.max
  actual_change = new_gold - hero.gold
  hero = Hero.new(name: hero.name, hero_class: hero.hero_class, hp: hero.hp, max_hp: hero.max_hp, level: hero.level, xp: hero.xp, xp_to_next: hero.xp_to_next, strength: hero.strength, dexterity: hero.dexterity, constitution: hero.constitution, intelligence: hero.intelligence, wisdom: hero.wisdom, charisma: hero.charisma, inventory: hero.inventory, gold: new_gold, armor_class: hero.armor_class, status_effects: hero.status_effects)

  if actual_change >= 0
    "💰 Gained **#{actual_change} gp** from #{reason}! Total gold: #{hero.gold} gp"
  else
    "💰 Spent **#{-actual_change} gp** on #{reason}! Total gold: #{hero.gold} gp"
  end
end

# 12. apply_status — Add/remove a status effect.
agent.register_tool("apply_status",
  "Apply or remove a temporary status effect on the hero (poisoned, blinded, charmed, frightened, stunned, invisible, etc.).",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {
      effect:   {type: "string", description: "Name of the status effect (e.g. 'poisoned', 'blinded', 'invisible', 'charmed', 'frightened', 'stunned', 'prone', 'grappled')"},
      remove:   {type: "boolean", description: "Set to true to remove this effect instead of applying it"},
      duration: {type: "string", description: "How long the effect lasts (e.g. '1 minute', 'until saved', '1 hour')"},
    },
    required: ["effect", "remove"],
  })
) do |args|
  effect = args["effect"]?.try(&.as_s) || "unknown"
  remove = args["remove"]?.try(&.as_bool) || false
  duration = args["duration"]?.try(&.as_s) || "unknown duration"

  current = hero.status_effects.dup

  if remove
    idx = current.index(effect)
    if idx
      current.delete_at(idx)
      hero = Hero.new(name: hero.name, hero_class: hero.hero_class, hp: hero.hp, max_hp: hero.max_hp, level: hero.level, xp: hero.xp, xp_to_next: hero.xp_to_next, strength: hero.strength, dexterity: hero.dexterity, constitution: hero.constitution, intelligence: hero.intelligence, wisdom: hero.wisdom, charisma: hero.charisma, inventory: hero.inventory, gold: hero.gold, armor_class: hero.armor_class, status_effects: current)
      "✅ **#{effect}** removed from #{hero.name}."
    else
      "⚠️ #{hero.name} doesn't have the '#{effect}' effect."
    end
  else
    current << effect unless current.includes?(effect)
    hero = Hero.new(name: hero.name, hero_class: hero.hero_class, hp: hero.hp, max_hp: hero.max_hp, level: hero.level, xp: hero.xp, xp_to_next: hero.xp_to_next, strength: hero.strength, dexterity: hero.dexterity, constitution: hero.constitution, intelligence: hero.intelligence, wisdom: hero.wisdom, charisma: hero.charisma, inventory: hero.inventory, gold: hero.gold, armor_class: hero.armor_class, status_effects: current)
    "🌀 **#{effect}** applied to #{hero.name} for #{duration}."
  end
end

# ──────────────────────────────────────────────────────────────────────────────
# Main game loop
# ──────────────────────────────────────────────────────────────────────────────
puts
puts "═══ Welcome, #{hero.name.colorize(:yellow).bold}! ═══".colorize(:green)
puts hero_summary(hero)

if resumed
  summarize_recent_history(agent.history)
end

puts

# ──────────────────────────────────────────────────────────────────────────────
# Opening narration — the DM kicks off the adventure (only for fresh games)
# ──────────────────────────────────────────────────────────────────────────────
unless resumed
  begin
    response = agent.ask("Begin the parody adventure! Describe where #{hero.name} finds themselves — probably in a rundown tavern, behind on rent, about to take a quest from someone who clearly has no authority to give one. Set the absurd scene. End by asking what they'd like to do.")
    response.stream do |chunk|
      if chunk.reasoning?
        STDOUT.print chunk.text.colorize(:dark_gray)
      elsif chunk.tool_call_name?
        STDOUT.print "⚡ #{chunk.text}".colorize(:yellow)
      elsif chunk.tool_call_args?
        STDOUT.print chunk.text.colorize(:light_cyan)
      else
        STDOUT.print chunk.text
      end
    end
    STDOUT.puts
    puts
    save_session(hero, agent)
  rescue ex
    STDERR.puts "  ✗ DM error: #{ex.message}".colorize(:red)
    puts
  end
end

puts "── Commands: /hero  /reset  /exit  /help ──".colorize(:dark_gray)
puts

def read_multiline : String?
  print "⚔️ ".colorize(:yellow)
  lines = [] of String
  loop do
    line = gets
    if line.nil?
      puts if lines.empty?
      break
    end
    lines << line
    break if line.strip.empty? && !lines.empty?
  end
  return nil if lines.empty?
  # Remove trailing empty lines if multi-line
  result = lines.join("\n").strip
  return nil if result.empty?
  result
end

loop do
  input = read_multiline
  break unless input

  case input.strip
  when "/exit", "/quit"
    break
  when "/reset"
    puts "  (Restarting adventure...)".colorize(:cyan)
    puts
    hero = select_hero
    puts
    puts "═══ Welcome, #{hero.name.colorize(:yellow).bold}! ═══".colorize(:green)
    puts hero_summary(hero)
    puts
    agent.reset
    puts "  (History cleared, new adventure begins!)".colorize(:cyan)
    puts
    next
  when "/hero"
    puts hero_summary(hero)
    puts
    next
  when "/help"
    puts "  Commands:".colorize(:cyan)
    puts "    /hero   — Show your character sheet".colorize(:dark_gray)
    puts "    /reset  — Restart with a new hero".colorize(:dark_gray)
    puts "    /exit   — Quit the game".colorize(:dark_gray)
    puts "    /help   — Show this help".colorize(:dark_gray)
    puts
    next
  end

  # Check if hero is alive before processing input
  if hero.hp <= 0
    puts "  ☠️ #{hero.name} is dead. Use /reset to start a new game.".colorize(:red).bold
    puts
    next
  end

  begin
    response = agent.ask(input)

    response.stream do |chunk|
      if chunk.reasoning?
        STDOUT.print chunk.text.colorize(:dark_gray)
      elsif chunk.tool_call_name?
        STDOUT.print "⚡ #{chunk.text}".colorize(:yellow)
      elsif chunk.tool_call_args?
        STDOUT.print chunk.text.colorize(:light_cyan)
      else
        STDOUT.print chunk.text
      end
    end

    STDOUT.puts
    puts
    save_session(hero, agent)
  rescue ex
    STDERR.puts "  ✗ DM error: #{ex.message}".colorize(:red)
    puts
  end
end

agent.close
puts
puts "═══ Thanks for playing! ═══".colorize(:yellow).bold
puts
