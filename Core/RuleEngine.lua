local addonName, ns = ...

local RuleEngine = {}
ns:RegisterModule("RuleEngine", RuleEngine)

local Constants = ns.Constants

-------------------------------------------------
-- Rule Evaluator Registry
-------------------------------------------------

local evaluators = {}

function RuleEngine:RegisterEvaluator(ruleType, evaluatorFunc)
    evaluators[ruleType] = evaluatorFunc
end

function RuleEngine:GetEvaluator(ruleType)
    return evaluators[ruleType]
end

function RuleEngine:GetRegisteredTypes()
    local types = {}
    for ruleType in pairs(evaluators) do
        table.insert(types, ruleType)
    end
    return types
end

-------------------------------------------------
-- Rule Evaluation
-------------------------------------------------

-- Evaluate a single rule against item data
-- Returns: boolean
function RuleEngine:Evaluate(rule, itemData, context)
    local ruleType = rule.type
    local ruleValue = rule.value

    local evaluator = evaluators[ruleType]
    if not evaluator then
        -- Unknown rule type, return false
        return false
    end

    return evaluator(ruleValue, itemData, context)
end

-- Evaluate multiple rules with match mode
-- matchMode: "any" (OR, with required-rule override) or "all" (AND)
-- In "any" mode, rules flagged `required = true` must ALL pass, and at least
-- one non-required rule must pass. If every rule is required, all-required-pass
-- is sufficient. In "all" mode the `required` flag is ignored.
-- Returns: boolean
function RuleEngine:EvaluateAll(rules, itemData, context, matchMode)
    if not rules or #rules == 0 then
        return false
    end

    matchMode = matchMode or "any"

    if matchMode == "all" then
        -- All rules must match (AND)
        for _, rule in ipairs(rules) do
            if not self:Evaluate(rule, itemData, context) then
                return false
            end
        end
        return true
    else
        -- "any" with required-rule semantics
        local hasNonRequired = false
        local anyNonRequiredPassed = false
        for _, rule in ipairs(rules) do
            local passed = self:Evaluate(rule, itemData, context)
            if rule.required then
                if not passed then
                    return false
                end
            else
                hasNonRequired = true
                if passed then
                    anyNonRequiredPassed = true
                end
            end
        end
        if hasNonRequired then
            return anyNonRequiredPassed
        end
        -- Every rule was required and all passed
        return true
    end
end

-------------------------------------------------
-- Context Builder
-------------------------------------------------

-- Build evaluation context from bag/slot info
function RuleEngine:BuildContext(bagID, slotID, isOtherChar)
    return {
        bagID = bagID,
        slotID = slotID,
        isOtherChar = isOtherChar or false,
    }
end
