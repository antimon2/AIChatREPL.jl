module TextDavinci003

using ..AIChatREPL: OPENAI_API_KEY, tryrequest_with_spinner
using OpenAI

const MODEL_ID = "text-davinci-003"

function request_and_return_contents(
    prompt;
    temperature=0,  # Randomness Control [0-1]
    max_tokens=1000,  # Maximum number of returned response tokens
    top_p=1.0,  # Controlling Diversity [0-1]
    frequency_penalty=0.0,  # Frequency Control [0-2]: Higher value makes it not to be repeat the same topics.
    presence_penalty=0.0,  # New Topic Control [0-2]: High value makes it easier for new topics to emerge.
)
    r = tryrequest_with_spinner() do
        create_completion(
            OPENAI_API_KEY[],
            MODEL_ID;
            prompt=prompt,
            temperature,  # Randomness Control [0-1]
            max_tokens,  # Maximum number of returned response tokens
            top_p,  # Controlling Diversity [0-1]
            frequency_penalty,  # Frequency Control [0-2]: Higher value makes it not to be repeat the same topics.
            presence_penalty,  # New Topic Control [0-2]: High value makes it easier for new topics to emerge.
        )
    end
    [choice["text"] for choice in r.response["choices"]]
end

end