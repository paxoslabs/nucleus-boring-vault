Transit Stations – Smart Contract Design Doc
🎁 3. User-Flows
What does the user interaction with the protocol look like? Map out user flows.

High Level Flows
Single Chain
User deposits 10 USDC says “I want USDG”
We determine fees* of 0.01 USDC rate of 1:1
We set a “receipt” for that user of 9.99 USDG
Once the USDG is ready, the bot calls “fulfill” on that receipt to grant the USDG to the user and burn the receipt

Multi Chain
User deposits 10 USDC on BASE says “I want USDG” on ETHEREUM
We determine fees* of 0.01 USDC rate of 1:1
We send a crosschain message to ETHEREUM of a “receipt” for that user of 9.99 USDG.
The ETHEREUM station contract notes that receipt
Once the USDG is ready, the bot calls “fulfill” on that receipt to grant the USDG to the user and burn the receipt


🔑 4. Key Design Decisions (KDDs)
Given assumptions about the environment the system operates in, we identify problems the system must handle. 

Each problem leads to one or more key design decisions (KDDs)


KDDs
Must be numbered for communication
KDD 1: Complex Configuration – Should We Use A Merkle Root
(NUM_CHAINS * NUM_ASSETS)^2
Is the number of combinations of routes to configure. Because this is so many and so annoying to keep track of we considered using merkle roots and a merkle tree to allow users to “prove” their route was valid on submission. Check for more details in the Transit Stations – Smart Contract Project Doc

Decision: Nothing fancy. Just configure per chain with mappings
UX cost is just too large for internal benefits. We can’t require users go and prove their route is valid. And also not have the contract provide getters for route data.

KDD 2: Pending Order Storage
We need to store pending orders in a way that allows us to iterate them on the backend. And also allows us to remove any element in a batch in O(1).

What data structure should hold these?

Decision: DO NOT SWAP AND POP as is described in preserved notes. This does not allow BATCH processing as swaps change the order mid batch. We should instead use a simple enumerableSet of order UUIDs and then map those to the structs.

KDD 3: Order Hashes vs. Full Order Data Bridged
Should we bridge over just a hash of the order or the whole order data? It’s cheaper to just bridge a hash, but all the real data must be stored somewhere.

Decision: Full order data bridged
If bridging hashes it’s a small gas savings to have to store all the data offchain. Perhaps we can include this in a future version if gas savings becomes paramount.
KDD 4: LZ vs. CCIP
We need to choose between LZ and CCIP. LZ has obviously been in the news lately in the not best light, and CCIP is seen as the more secure alternative. But CCIP is slow and non-configurable in it’s speed. And also more expensive.

Decision: LZ
Reason lies in LZ allowing for configuration with block confirmations. CCIP is too rigid and will not allow us to have the speed transit needs.
KDD 5: Upgradeability for Contracts
Decision: We do not want to not make contracts upgradeable. For iteration, we will have to release new immutable versions of the protocol.

No sense in changing protocol now, and transit is still able to retain support for old versions while migrating to new ones.

KDD 6: Protocol Initiated Refunds
Should the protocol be able to issue refunds? It would have to send back the message to the source chain to be processed there as a refund. 

Decision: Let the fund management remain under control of the vault. Keep the station in charge of station stuff. Which means just a owner only function for removing an order from the array.

It’s not a new trust assumption to have admins move funds back to the source chain and give them back to the user. Or to have an admin able to remove orders from the queue. These admins already have god mode control over funds.
KDD 7: Customer Initiated Refunds
Should the customer be able to cancel orders and request a refund? Same quirks exist as the previous KDD, but the user is triggering it. 

Decision: No customers can initiate their refunds. 

We’ve already determined that the user should not be able to command when/where funds are released. This is antithetical to the foundations of Transit in this regard.

KDD 8: Partial Fills
Should we allow partial fills?

Decision: Allow partial fills – we don’t have to use it. But because it’s trivially simple for smart contracts to subtract amount from orders until == 0 then remove. But not allow partail fills below the minimum order size.

We want to enable partial fills technically from the smart contract perspective but practically not have to consider them and just fill orders in full for now. But the optionality is strictly better.

KDD 9: Max Order Size – Rate Limits
Should we include a max order size as a sort of rate limit? Or another rate limit? With LZ we have re-org risk, and that means that we want to rate limit risk. 

Decision: No Max order size on contract level. But implement sliding window rate limits offchain based on max amount of capital at reorg risk. 

It’s too difficult to meaningfully limit this on the contract level. The sort of rolling window can just be gamed as there’s no way to be sure you’re syncing up your rolling window of blocks with the blocks that are suitable for a reorg. It’s just much easier to watch this from the offchain perspective and enforce any rate limits and emergency stops there since the backend is who releases funds anyways.
KDD 10: Min Order Size
Should we include a min order size? Someone can grief by spamming small orders that we must pay gas to orchestrate and execute. This griefer will need to pay lots of gas as well, but the impact can be minimized with a sensible minimum. 

Decision: Set a min order size on source chain – per order

It makes sense to allow a min order size, more optionality doesn’t hurt to have to prevent tiny amounts clogging our system in case fees are not able to be dialed perfectly. 

KDD 11: Order Expiry 
Should orders be able to expire? Whether users or the protocol provide an expiration time.

Decision: No expiry

Adding expiry introduces too many issues with keeping track of liquidity and needing to essentially go back and offer refunds. All the problems with refunds apply here. We can either manually go and refund if it’s a huge problem, or they can wait.

KDD 12: Cross Chain & Single Chain
Should we allow crosschain and single chain?

Decision: We need to allow both single chain as well as crosschain paths. 

We need to be able to do both as a core product requirement. People need to orchestrate between coins and/or  between chains. 
KDD A: Privileged Execution?
Will users be executing the “claims” on receipts? Or will we?
Decision: Only us. We don’t want users determining when liquidity leaves the system ever.
The point of the orchestration here is for one intelligent entity to have a global view of all trades and find the optimal solve and then execute. So we should not allow permissionless “claims” as that will mess up the optimal logic.
KDD B: Flat Fees?
We plan on having percent fees, but should we also include flat fees to cover orchestration costs? This sounds like an easy decision for us but it’s not communicated with anyone else yet. 

Decision: Yes. Have it configured in the same way as the percent fee regarding KDD C. 

We want to be sure we can cover gas costs for orchestration and execution.

KDD C: Min Amount Per Route?
Should minAmount be able to be configured per route or per station? 

Decision: Per route. 

At this point we need to configure per route anyways so this is more optionality for minimal extra effort
KDD D: Force remove pending order in partial amounts?
Should we be able to force remove orders in partial amounts?

Decision: No. 

This flow is not useful for anything and only allows us to make mistakes. Situations of only filling partially is already covered with partial fill + removal.

KDD E: Additive Fees?
Additive fees are when you compute the fees as the sum of the flat fee + the percentage of the principal. Charge those fees. It’s possible to charge the percent fees on the amount AFTER the flat fee. But that is not additive.

Decision: Yes. 

This is already the industry and PXL standard. No sense and more confusing to take percentage fees after flat fees

KDD F: LayerZero Config Definition for Low Latency Without Sacrificing Security
For LZ we don’t want to choose arbitrary values for the block confirmations. How do we determine a number with a good explanation for why?

Estimated Total Delivery Time:  You can estimate the total message delivery time with the following formula:

Total Time ≈ (sourceBlockTime × number of block confirmations) + (destinationBlockTime × (2 blocks + number of DVNs))

Assuming we don’t sacrifice on DVNs (Assume 3 DVNs)
Total Time ≈ (sourceBlockTime * number of block confirmation) + (destinationBlockTime * 5)

Assume sourceBlockTime = 12 (Eth mainnet)
Assume destinationBlockTime = 2 (robinhood chain)
Assume block confirmations = 15 (current default lz config)

Total time ~ (12 * 15) + (2 * 5) = 190 seconds = 190 / 60 = 3.167 mins

Decision: N/A





🛠 5. Software-Level Requirements
A more granular description of the contracts. If a Spike was used, it may be helpful to have an AI translate your code to this section. Just remember to evaluate every line an AI produces and be vigilant against overly verbose slop.
Libraries
Define what libraries and dependencies we are using.


Solmate
RolesAuthority
LayerZero
OAppAuth – Our own version of OApp contract built with Roles Authority. Already in use for the teller
Auth
Define ownership models and privileged actions.

OWNER
EXECUTOR
Roles Authority role to execute. Must use a roles authority then and not just use Auth as ownable.
Data Structures
Define data structures, and what it does.

Route
destChainEID
offerAsset
wantAsset

RouteConfig
isSupported
flatFeeProtocol
percentFeeProtocol
flatFeeSigner
percentFeeSigner
minAmount

pendingOrder
Asset
amountDue
Receiver
Source chain
offerAmount
Receive time
offerAsset

Policy System
mapping(address => string) signerPolicies;
mapping(string => mapping(Route => RouteConfig)) routeConfigForPolicy;
String constant defaultPolicy;


pendingOrders enumerable set. 
enumerableSet(bytes32 => bytes32)
mapping(bytes32 => Order);

This way we can iterate through orders and also remove them easily in batches.
Variables
Define types, visibility, and what it does.

thisChainEID
This contracts EID so we know if a provided route is crosschain or not
Non-View Functions
Define non-view functions, modifiers, and what it does. 

setRootConfig(Route[] routes, RouteConfig[] routeConfigs) onlyOwner {}
No merkle route. MUST be batches.

submitOrder(Route route, uint amount, address receiver, uint feFeePercent, bytes signature) {}
Give the station the route, amount and receiver. Route contains the offer/want asset as well as the destination chain. A feFeePercent can be provided optionally and the signature must either be empty or map to a signer with a policy.

_lzReceive(...){}
Override for LZ to handle receives. Get the data, make sure it’s from a valid route and then if all is good, push onto the pendingOrders.

executePendingOrders(uint[] pendingOrdersIndex, uint[] amounts) requiresAuth {}
Amount is subtracted from the order’s amountDue, if the new amountDue == 0, then remove the order from the array.

forceRemovePendingOrder(uint pendingOrdersIndex) onlyOwner {}
Admin function to force remove a pending order in its entirety. No partial fills allowed on this

recoverETH()
Being LZ, ETH will be sent to this contract. Need owner ability to recover it to the owner address. Not configurable to other receivers.

recoverTokens()
Similar to the above but for ERC20s lost in the contract.

setUserPolicy(string policy, address user)
Sets a signers policy. Owner only.

function setPolicy(string policy, Route[] routes, RouteConfig routeConfigs[])
For some policy set the routes/routeConfigs. Owner only
View Functions
Define view functions and what it does. 


getRouteConfig(Route route)
Need a view function to get a route’s config

getPendingOrders()
Get the pending orders
Events
Define events and what information the offchain elements will require from them

Need normal events for all state changes. But especially need care with receipt handling:
Need an event with an order’s details & route on submission
Need an event with order’s details & route & index on receive
Need an event with order’s details & index on execution
Force removals have their own unique event with the same data
🧪 6. Testing Requirements
Define what we are testing and how we are testing. Describe the overall structure for how we can simplify testing structure with helpers/base contracts.

Base Test 
Unit tests
Integration tests
Invariant tests

# Fee System Design
Fee System Design
Requirements
Taking fees unique to each platform. (required)
Allowing the platform to take fees from its users. (optional) 

Fee System
Route
destChainEID
offerAsset
wantAsset
RouteConfig
isSupported
flatFeeProtocol
percentFeeProtocol
flatFeeSigner
percentFeeSigner
minAmount

mapping(Route => RouteConfig) routePolicy;

Policy System
mapping(string => RoutePolicy) policies;
mapping(address => string) signerPolicy;
String defaultPolicy;

This way we can make Routes like RolesAuthority Roles. Each signer has a policy assigned and that is what route config they have. This way we can easily re-use and name route policies for users.

Frontend Fees
When submitting a transit request, signers may provide a frontend fee they want to charge. This is the same approach as UniswapX. This allows the frontends to charge more dynamic fees by just setting what they want it to be in the call as it’s constructed. 

Question
We can choose to cap frontend fees to prevent customers from misconfiguring or maliciously charging users, or not. I would say we should have this, but I cannot come up with a good explanation for why a particular number should be chosen.

How This All Works
Here’s some pseudocode for how this could all work:

Note how the FE integration is a “signer” who we are expecting to sign an order to get custom fee rules and route configurations.

struct Route{
	uint destEID;
	address offerAsset;
	address wantAsset;
}
struct RouteConfig {
	bool isSupported;
	uint flatFeeProtocol;
	uint percentFeeProtocol;
	uint flatFeeSigner;
	uint percentFeeSigner;
	uint minAmount;
}

mapping(Route => RouteConfig) routePolicy;
mapping(address => string) signerPolicies;

mapping(string => mapping(Route => RouteConfig)) routeConfigForPolicy;
string constant DEFAULT_POLICY = "DEFAULT";
address constant PROTOCOL = 0x000000abcd;

function submitOrder(Route route, uint amount, address receiver, uint feFeePercent, bytes signature) external {
	string policy;
	if(signature.length == 0){
		policy = DEFAULT_POLICY;
}else{
address signer = ecrecover(signature);
policy = signerPolicies[signer];
if(policy == "") revert();
}

RouteConfig config = routeConfigForPolicy[policy][route];
if(!config.isSupported) revert();

// Note signerFeeTotal will include the feFeePercent charged by the FE as well as the // flatFeeSigner and percentFeeSigner calculated if a "builder codes" type thing is // used in this policy.
(uint signerFeeTotal, uint protocolFeeTotal) = _calcFees(config, feFeePercent, amount);

uint fees = feFeeTotal + protocolFeeTotal;

(route.offerAsset).transfer(signer, signerFeeTotal);
(route.offerAsset).transfer(PROTOCOL, protocolFeeTotal);

_bridgeOrPushToSet(route, amount - fees, receiver, signer);
}

function setUserPolicy(string policy, address user) external onlyOwner {
	signerPolicies[user, policy];
}

function setPolicy(string policy, Route[] routes, RouteConfig routeConfigs[]) external onlyOwner {
	for route,routeConfig in routes, routeConfigs{
		routeConfigForPolicy[policy][route] = routeConfig;
}
}