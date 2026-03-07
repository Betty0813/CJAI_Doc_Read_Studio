import asyncio
import random
import time
import os
import json
from datetime import datetime
from typing import List, Dict, Optional, Callable, Awaitable
from openai import OpenAI, AsyncOpenAI
from .document_parser import parse_document
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type
from .token_tracker import token_tracker
import structlog
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Load configuration
def load_config():
    config_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "config.json")
    try:
        with open(config_path, 'r') as f:
            return json.load(f)
    except Exception as e:
        print(f"Warning: Could not load config file: {e}")
        return {}

config = load_config()

# Set up logger for this module
logger = structlog.get_logger(__name__)

# Define retry decorator for agent invocations
@retry(
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=2, max=10),
    retry=retry_if_exception_type((Exception,)),
    reraise=True
)
async def invoke_agent_with_retry(
    system_prompt: str,
    user_prompt: str,
    agent_name: str = "unknown",
    session_id: str = None,
    model: str = None
) -> tuple[str, float]:
    """Invoke OpenAI compatible API with retry logic and performance tracking."""
    start_time = time.time()
    try:
        # Initialize OpenAI client with custom base URL if provided
        api_key = os.environ.get("OPENAI_API_KEY")
        base_url = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1")

        if not api_key:
            raise ValueError("OPENAI_API_KEY environment variable not set")

        client = OpenAI(
            api_key=api_key,
            base_url=base_url
        )

        response = client.chat.completions.create(
            model=model or "gpt-4o-mini",
            max_tokens=2048,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt}
            ]
        )

        response_text = response.choices[0].message.content
        response_time = time.time() - start_time

        # Log performance metrics
        logger.info(
            "Agent response completed",
            agent_name=agent_name,
            response_time_seconds=round(response_time, 2),
            response_length=len(response_text),
            tokens_per_second=round(len(response_text.split()) / response_time, 2) if response_time > 0 else 0,
            input_tokens=response.usage.prompt_tokens,
            output_tokens=response.usage.completion_tokens
        )

        # Track costs if session and model info provided
        if session_id and model:
            token_tracker.track_agent_invocation(
                session_id=session_id,
                agent_name=agent_name,
                model=model,
                input_text=user_prompt,
                output_text=response_text,
                response_time=response_time
            )

        return response_text, response_time
    except Exception as e:
        response_time = time.time() - start_time
        logger.warning(
            "Agent invocation failed, will retry",
            agent_name=agent_name,
            attempt_time_seconds=round(response_time, 2),
            error=str(e)
        )
        raise

def get_bedrock_model_id(model_name: str) -> str:
    """Map user-friendly model names to OpenAI compatible model IDs from config."""
    models = config.get("models", {}).get("available", [])

    # Create a mapping from model values to model_ids
    model_mapping = {model["value"]: model["model_id"] for model in models}

    # Get the model_id for the given model_name, with fallback
    default_model = config.get("models", {}).get("default_team", "gpt-4o-mini")
    default_model_id = model_mapping.get(default_model, "gpt-4o-mini")

    return model_mapping.get(model_name, default_model_id)

async def create_agent(member, documents_content: str, conversation_history: str, custom_system_prompt: str = None) -> dict:
    """Create a Claude agent configuration for a team member."""

    # Special handling for Team Moderator
    if member.name == "Team Moderator":
        system_prompt = f"""You are the Team Moderator, a specialized agent responsible for analyzing and synthesizing feedback from all team members after they have reviewed documents.

YOUR CORE RESPONSIBILITIES:
1. CONFLICT ANALYSIS: Identify any conflicting recommendations, disagreements, or contradictory suggestions between team members
2. SYNERGY IDENTIFICATION: Highlight areas where team members' feedback reinforces, complements, or builds upon each other
3. ACTIONABLE SYNTHESIS: Provide a consolidated summary that reconciles conflicts and leverages synergies
4. QUESTION CONSOLIDATION: Collect and organize all clarification questions from team members

ANALYSIS FRAMEWORK:
🔍 CONFLICT DETECTION:
- Look for contradictory recommendations (e.g., one suggests adding detail, another suggests removing it)
- Identify disagreements on priorities, approaches, or solutions
- Note when team members have opposing viewpoints on the same issue

🤝 SYNERGY IDENTIFICATION:
- Find recommendations that complement each other
- Identify themes that multiple team members mentioned
- Highlight areas where different expertise domains reinforce the same conclusion

🤔 QUESTION CONSOLIDATION:
- Extract all clarification questions marked with "### 🤔 Clarification Questions" from team members
- Group related questions together to avoid redundancy
- Present questions clearly with context about which team member asked and why it matters
- Prioritize questions that multiple team members have raised or that block important decisions

📋 SYNTHESIS GUIDELINES:
- Start with "## Cross-Team Analysis" as your heading
- Use clear sections: **Conflicts Identified**, **Synergies Found**, **Consolidated Questions**, **Synthesized Recommendations**
- For conflicts: suggest resolution approaches or note when both perspectives have merit
- For synergies: consolidate similar suggestions into stronger, unified recommendations
- For questions: present them clearly organized by topic/priority
- Provide specific, actionable next steps that account for all team input
- Always reference which team members contributed to each point

DOCUMENTS TO REVIEW:
{documents_content}

CONVERSATION CONTEXT:
{conversation_history}

RESPONSE STRUCTURE:
## Cross-Team Analysis

### 🔴 Conflicts Identified
[List any contradictory recommendations with suggested resolutions]

### 🟢 Synergies Found
[Highlight reinforcing feedback and complementary suggestions]

### 🤔 Consolidated Questions for Clarification
[Present all team questions organized by topic, with context about who asked and why it matters]

### 📋 Synthesized Recommendations
[Consolidated, actionable recommendations that resolve conflicts and leverage synergies]

Be diplomatic but clear about conflicts. Focus on creating actionable consensus while respecting all perspectives. Ensure all team questions are captured and presented clearly."""

    # Use custom system prompt if provided (for templates), otherwise use default
    elif custom_system_prompt:
        base_instructions = custom_system_prompt

        # Add document and conversation context to the custom prompt
        system_prompt = f"""{base_instructions}

DOCUMENTS TO REVIEW:
{documents_content}

CONVERSATION CONTEXT:
{conversation_history}

ADDITIONAL INSTRUCTIONS:
- ALWAYS mention the specific filename when referencing content, making suggestions, or proposing changes
- Review the full conversation history to understand what others have said and build on previous discussion points
- You can use markdown formatting in your responses to improve readability
- Keep responses focused and actionable"""
    else:
        system_prompt = f"""You are {member.name}, a team member participating in a collaborative document review discussion.

Your role: {member.role}

DOCUMENTS TO REVIEW:
{documents_content}

CONVERSATION CONTEXT:
{conversation_history}

INSTRUCTIONS:
1. Carefully analyze ALL documents from the perspective of your role
2. Provide constructive feedback focused on how to improve each document - identify specific strengths, weaknesses, and actionable improvement recommendations
3. ALWAYS mention the specific filename when referencing content, making suggestions, or proposing changes (e.g., "In [filename.pdf], the section on..." or "The [filename.md] document should include...")
4. Review the full conversation history to understand what others have said and build on previous discussion points
5. Carefully evaluate other team members' suggestions and feedback - agree, disagree, or expand on their points when relevant
6. Avoid repeating what others have already covered - add unique value from your expertise
7. When suggesting improvements, be specific about what changes to make and why they would benefit the document
8. Consider how multiple documents relate to each other and identify gaps, overlaps, or inconsistencies between them
9. If responding to follow-up questions, directly address what was asked while maintaining focus on document improvement
10. Keep responses focused and concise (2-3 paragraphs maximum)
11. You can use markdown formatting in your responses to improve readability:
    - Use **bold** for emphasis on important points
    - Use bullet points or numbered lists for multiple suggestions
    - Use `code formatting` for technical terms or specific text references
    - Use ### headings to organize longer responses into sections
    - Use > blockquotes when quoting from documents

ASKING CLARIFICATION QUESTIONS:
You are encouraged to ask clarification questions when:
- The purpose or intent of something in the document is unclear
- You need to understand the expected outcome or result of a feature/section
- The reasoning behind a design decision or approach is not evident
- There are ambiguities that could lead to different interpretations
- Understanding the target audience or use case would help provide better feedback

Format clarification questions clearly using:
### 🤔 Clarification Questions
- **Question 1**: [Your specific question about purpose/intent/reasoning]
- **Question 2**: [Another question if needed]

These questions will be consolidated by the Team Moderator and presented to the user.

Your response should provide actionable, constructive feedback that helps improve the documents while clearly identifying which specific files need what changes."""

    bedrock_model_id = get_bedrock_model_id(member.model)

    # Return agent configuration instead of Agent object
    return {
        "name": member.name,
        "system_prompt": system_prompt,
        "model": bedrock_model_id
    }

def parse_multiple_documents(documents) -> str:
    """Parse multiple documents and wrap them in XML tags with filenames."""
    documents_content = ""

    for doc in documents:
        try:
            content = parse_document(doc["path"])
            filename = doc["filename"]

            documents_content += f"""<document filename="{filename}">
{content}
</document>

"""
        except Exception as e:
            # If a document fails to parse, include an error message
            documents_content += f"""<document filename="{doc['filename']}">
ERROR: Could not parse document - {str(e)}
</document>

"""

    return documents_content.strip()

async def run_discussion_round(
    session,
    documents,
    prompt: str,
    *,
    on_agent_start: Optional[Callable[[str], Awaitable[None]]] = None,
    on_agent_response: Optional[Callable[[Dict], Awaitable[None]]] = None,
) -> List[Dict]:
    """Run a discussion round with all team members. Callbacks allow streaming each response as it's ready."""
    try:
        # Parse all documents and wrap in XML tags
        documents_content = parse_multiple_documents(documents)

        # Build conversation history with XML tags for better agent understanding
        conversation_history = "<conversation_history>\n"
        for msg in session.conversation:
            if msg["type"] == "user":
                conversation_history += f"<user_message>{msg['content']}</user_message>\n"
            else:
                role = msg.get('role', 'Team Member')
                conversation_history += f"<agent_message agent='{msg['agent_name']}' role='{role}'>{msg['content']}</agent_message>\n"

        # Add current prompt
        conversation_history += f"<current_user_prompt>{prompt}</current_user_prompt>\n"
        conversation_history += "</conversation_history>"

        # Separate Team Moderator from other agents
        regular_agents = []
        moderator_agent = None
        moderator_member = None

        for member in session.team_members:
            agent = await create_agent(member, documents_content, conversation_history)
            if member.name == "Team Moderator":
                moderator_agent = agent
                moderator_member = member
            else:
                regular_agents.append((agent, member))

        # Shuffle order for random responses (only regular agents)
        random.shuffle(regular_agents)

        async def get_agent_response(agent, member):
            try:
                agent_prompt = f"""
Current discussion prompt: {prompt}

Please provide your perspective on this document and the current discussion from your role as {member.role}.
Focus on actionable feedback and insights specific to your expertise.
"""
                claude_model_id = get_bedrock_model_id(member.model)
                response_text, response_time = await invoke_agent_with_retry(
                    agent["system_prompt"], agent_prompt, member.name, session.session_id, claude_model_id
                )
                return {
                    "type": "agent",
                    "agent_id": member.id,
                    "agent_name": member.name,
                    "role": member.role,
                    "model": member.model,
                    "content": response_text,
                    "timestamp": datetime.now().isoformat(),
                    "response_time_seconds": round(response_time, 2),
                    "response_length": len(response_text)
                }
            except Exception as e:
                print(f"Error getting response from agent {member.name}: {str(e)}")
                return {
                    "type": "agent",
                    "agent_id": member.id,
                    "agent_name": member.name,
                    "role": member.role,
                    "model": member.model,
                    "content": f"I apologize, but I'm having trouble responding right now. Error: {str(e)}",
                    "timestamp": datetime.now().isoformat()
                }

        # Run regular agents one by one so we can stream each response as it's ready
        regular_responses = []
        for agent, member in regular_agents:
            if on_agent_start:
                await on_agent_start(member.name)
            response = await get_agent_response(agent, member)
            regular_responses.append(response)
            if on_agent_response:
                await on_agent_response(response)

        # Now run the Team Moderator after all other agents have responded
        moderator_response = None
        if moderator_agent and moderator_member:
            if on_agent_start:
                await on_agent_start(moderator_member.name)
            updated_conversation_history = conversation_history
            for response in regular_responses:
                updated_conversation_history += f"\n<agent_message agent='{response['agent_name']}' role='{response['role']}'>{response['content']}</agent_message>"
            moderator_agent = await create_agent(moderator_member, documents_content, updated_conversation_history)
            moderator_response = await get_agent_response(moderator_agent, moderator_member)
            if moderator_response and on_agent_response:
                await on_agent_response(moderator_response)

        all_responses = list(regular_responses)
        if moderator_response:
            all_responses.append(moderator_response)

        # ---- Multi-Agent Debate Round (stream each debate response) ----
        try:
            debate_responses = await run_debate_round(
                session, documents, all_responses, prompt,
                on_agent_start=on_agent_start,
                on_agent_response=on_agent_response,
            )
            if debate_responses:
                all_responses.extend(debate_responses)
        except Exception as de:
            logger.warning("Debate round failed (non-critical)", error=str(de))

        return all_responses

    except Exception as e:
        print(f"Error in discussion round: {str(e)}")
        return [{
            "type": "system",
            "content": f"Error running discussion round: {str(e)}",
            "timestamp": datetime.now().isoformat()
        }]


async def run_debate_round(
    session,
    documents,
    initial_responses: List[Dict],
    original_prompt: str,
    *,
    on_agent_start: Optional[Callable[[str], Awaitable[None]]] = None,
    on_agent_response: Optional[Callable[[Dict], Awaitable[None]]] = None,
) -> List[Dict]:
    """
    Multi-Agent Debate: 每个 Agent 看到其他 Agent 的回复后，
    可以挑战、支持或完善观点，形成真正的多 Agent 对话。
    """
    documents_content = parse_multiple_documents(documents)

    others_text = ""
    for resp in initial_responses:
        if resp.get("type") != "agent":
            continue
        others_text += (
            f"\n--- {resp['agent_name']} ({resp.get('role', '')}) ---\n"
            f"{resp['content']}\n"
        )

    if not others_text.strip():
        return []

    debate_members = [m for m in session.team_members if m.name != "Team Moderator"]
    if not debate_members:
        return []

    debate_system = """You are {name}, participating in a multi-agent debate about document review.

Your role: {role}

OTHER AGENTS' INITIAL FEEDBACK:
{others}

DOCUMENTS:
{docs}

YOUR TASK — DEBATE ROUND:
1. Read the other agents' feedback carefully.
2. CHALLENGE points you disagree with — explain why, citing evidence from the document.
3. SUPPORT points you strongly agree with — add your perspective or additional evidence.
4. REFINE suggestions by other agents — make them more specific or actionable.
5. Raise any NEW insights triggered by reading others' feedback.

RULES:
- Address other agents BY NAME when responding to their points.
- Be constructive — disagreement is valuable when backed by reasoning.
- Keep it concise (1-2 paragraphs).
- Start with "## Debate Response" as your heading.
- Format your response as:
  ### Agreements
  ### Challenges
  ### New Insights"""

    async def get_debate_response(member):
        try:
            system = debate_system.format(
                name=member.name,
                role=member.role,
                others=others_text[:6000],
                docs=documents_content[:4000],
            )
            model_id = get_bedrock_model_id(member.model)
            text, resp_time = await invoke_agent_with_retry(
                system,
                f"Original discussion prompt: {original_prompt}\n\nProvide your debate response.",
                f"{member.name} (debate)",
                session.session_id,
                model_id,
            )
            return {
                "type": "agent",
                "agent_id": member.id,
                "agent_name": f"{member.name} (Debate)",
                "role": member.role,
                "model": member.model,
                "content": text,
                "timestamp": datetime.now().isoformat(),
                "response_time_seconds": round(resp_time, 2),
                "response_length": len(text),
                "is_debate": True,
            }
        except Exception as e:
            logger.warning(f"Debate response failed for {member.name}", error=str(e))
            return None

    # Run debate agents one by one so we can stream each response
    results = []
    for member in debate_members:
        if on_agent_start:
            await on_agent_start(f"{member.name} (debate)")
        r = await get_debate_response(member)
        if r is not None:
            results.append(r)
            if on_agent_response:
                await on_agent_response(r)
    return results


async def generate_actionable_summary(session, documents, model: str = "claude-3-haiku") -> str:
    """Generate an actionable summary of all suggestions from the conversation."""
    try:
        # Parse all documents and wrap in XML tags
        documents_content = parse_multiple_documents(documents)

        # Extract all agent suggestions from the conversation
        all_suggestions = []
        for msg in session.conversation:
            if msg["type"] == "agent":
                all_suggestions.append({
                    "agent": msg["agent_name"],
                    "role": msg["role"],
                    "content": msg["content"]
                })

        # Build suggestions text for the summary agent
        suggestions_text = "<all_suggestions>\n"
        for i, suggestion in enumerate(all_suggestions, 1):
            suggestions_text += f"<suggestion_{i} from='{suggestion['agent']}' role='{suggestion['role']}'>\n"
            suggestions_text += suggestion['content']
            suggestions_text += f"\n</suggestion_{i}>\n\n"
        suggestions_text += "</all_suggestions>"

        # Create a specialized system prompt for actionable summary
        system_prompt = f"""You are an expert project manager and document analyst creating an actionable summary.

DOCUMENTS REVIEWED:
{documents_content}

ALL TEAM SUGGESTIONS:
{suggestions_text}

TASK: Create a comprehensive, prioritized actionable summary in markdown format that consolidates ALL suggestions into a clear action plan.

FORMAT REQUIREMENTS:
1. Start with a brief overview of the documents reviewed
2. Create a numbered list of actionable items (minimum 10, maximum 25)
3. Each item should be specific, measurable, and implementable
4. Assign priority levels: 🔴 Critical, 🟡 Important, 🟢 Nice to Have
5. Group related suggestions together to avoid redundancy
6. For each action item, include stakeholder attribution showing which roles suggested or support it
7. Include specific file references when relevant
8. End with a brief implementation timeline suggestion

STAKEHOLDER ATTRIBUTION FORMAT:
- For each action item, add: **Stakeholders**: [Role1, Role2]
- Use the team member roles (not names) from the suggestions
- If multiple team members with the same role suggested similar items, mention the role once
- If different roles suggested the same item, list all supporting roles

EXAMPLE ACTION ITEM FORMAT:
1. 🔴 **Add executive summary section to `project_plan.md`**
   - Provide a 2-3 paragraph overview highlighting key objectives, timeline, and expected outcomes
   - **Stakeholders**: [Product Strategy and Market Analysis, Technical Architecture and Implementation]

Use proper markdown formatting:
- Use # for main title, ## for section headers
- Use **bold** for emphasis
- Use - or * for bullet points
- Use numbered lists (1. 2. 3.) for action items
- Use `backticks` for technical terms or file references
- Use > for important notes or quotes

Output clean markdown that can be directly saved as a .md file."""

        # Create the summary configuration with selected model
        claude_model_id = get_bedrock_model_id(model)

        # Generate the summary with retry logic and performance tracking
        summary_prompt = "Please generate the actionable summary in markdown format as specified."
        claude_model_id = get_bedrock_model_id(model)
        summary_markdown, summary_time = await invoke_agent_with_retry(
            system_prompt, summary_prompt, "ActionableSummaryAgent", session.session_id, claude_model_id
        )

        logger.info(
            "Actionable summary generated",
            model=model,
            generation_time_seconds=round(summary_time, 2),
            summary_length=len(summary_markdown)
        )

        return summary_markdown

    except Exception as e:
        print(f"Error generating actionable summary: {str(e)}")
        return f"# Actionable Summary\n\nError generating summary: {str(e)}"

async def run_discussion_round_with_templates(session, session_documents, prompt, template_prompts=None):
    """Run a discussion round with custom template system prompts."""
    try:
        logger.info(f"Starting template-based discussion round with {len(session.team_members)} members")

        # Parse documents
        documents_content = parse_multiple_documents(session_documents)

        # Build conversation history
        conversation_history = "<conversation_history>\n"
        for msg in session.conversation:
            if msg["type"] == "user":
                conversation_history += f"<user_message>{msg['content']}</user_message>\n"
            else:
                role = msg.get('role', 'Team Member')
                conversation_history += f"<agent_message agent='{msg['agent_name']}' role='{role}'>{msg['content']}</agent_message>\n"
        conversation_history += f"<current_user_prompt>{prompt}</current_user_prompt>\n"
        conversation_history += "</conversation_history>"

        # Create agents with template prompts
        agents = []
        for member in session.team_members:
            custom_prompt = template_prompts.get(member.id) if template_prompts else None
            agent = await create_agent(member, documents_content, conversation_history, custom_prompt)
            agents.append((agent, member))

        # Run agents in parallel using asyncio.gather for better performance
        tasks = []
        for agent, member in agents:
            agent_prompt = f"""
Current discussion prompt: {prompt}

Please provide your perspective on this document and the current discussion from your role as {member.role}.
Focus on actionable feedback and insights specific to your expertise.
"""

            task = invoke_agent_with_retry(
                agent, agent_prompt, member.name, session.session_id, get_bedrock_model_id(member.model)
            )
            tasks.append((task, member))

        # Wait for all responses
        responses = []
        for task, member in tasks:
            try:
                response_text, response_time = await task

                agent_response = {
                    "type": "agent",
                    "agent_id": member.id,
                    "agent_name": member.name,
                    "role": member.role,
                    "model": member.model,
                    "content": response_text,
                    "timestamp": datetime.now().isoformat(),
                    "response_time_seconds": round(response_time, 2),
                    "response_length": len(response_text)
                }
                responses.append(agent_response)

                # Track costs
                token_tracker.track_agent_invocation(
                    session.session_id, member.name, member.model,
                    agent_prompt, response_text, response_time
                )

            except Exception as e:
                logger.error(f"Agent {member.name} failed: {e}")
                error_response = {
                    "type": "agent",
                    "agent_id": member.id,
                    "agent_name": member.name,
                    "role": member.role,
                    "model": member.model,
                    "content": f"I apologize, but I'm having trouble responding right now. Error: {str(e)}",
                    "timestamp": datetime.now().isoformat()
                }
                responses.append(error_response)

        # Randomize response order for more natural discussion flow
        random.shuffle(responses)

        logger.info(f"Template discussion round completed with {len(responses)} responses")
        return responses

    except Exception as e:
        logger.error(f"Discussion round failed: {e}")
        raise
