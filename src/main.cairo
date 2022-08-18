%lang starknet
from starkware.cairo.common.math import assert_nn
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.hash import hash2
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_caller_address, get_block_timestamp
from starkware.cairo.common.math_cmp import is_le, is_not_zero
from starkware.starknet.common.syscalls import get_contract_address

from src.storage import (
    _domain_data,
    hash_domain,
    _address_to_domain_util,
    _address_to_domain,
    write_domain_data,
    write_address_to_domain,
    DomainData,
)
from src.interface.starknetid import StarknetID
from src.interface.pricing import Pricing

from cairo_contracts.src.openzeppelin.token.erc20.IERC20 import IERC20

# EXTERNALS CONTRACT ADDRESSES

const STARKNETID_CONTRACT = 0x0798e884450c19e072d6620fefdbeb7387d0453d3fd51d95f5ace1f17633d88b
const PRICING_CONTRACT = 0x0798e884450c19e072d6620fefdbeb7387d0453d3fd51d95f5ace1f17633d88b

# USER VIEW FUNCTIONS

@view
func domain_to_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    domain_len : felt, domain : felt*
) -> (address : felt):
    let (hashed_domain) = hash_domain(domain_len, domain)
    let (domain_data) = _domain_data.read(hashed_domain)
    if domain_data.address == FALSE:
        let (token_id : Uint256) = domain_to_token_id(domain_len, domain)
        return (0)
    else:
        return (domain_data.address)
    end
end

@view
func address_to_domain{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    address : felt
) -> (domain_len : felt, domain : felt*):
    alloc_locals
    let (arr : felt*) = alloc()
    let (arr_len : felt) = _address_to_domain_util(address, arr, 0)
    return (arr_len, arr)
end

@view
func domain_to_token_id{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    domain_len : felt, domain : felt*
) -> (owner : Uint256):
    let (hashed_domain) = hash_domain(domain_len, domain)
    let (domain_data) = _domain_data.read(hashed_domain)
    let owner = domain_data.owner

    if owner.low == 0 and owner.high == 0:
        if domain_len == 0:
            let false = Uint256(0, 0)
            return (false)
        end
        return domain_to_token_id(domain_len - 1, domain + 1)
    end
    return (owner)
end

# USER EXTERNAL FUNCTIONS

@external
func set_domain_to_address{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    domain_len : felt, domain : felt*, address : felt
):
    ret
end

@external
func set_address_to_domain{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    address : felt, domain_len : felt, domain : felt*
):
    ret
end

@external
func buy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    token_id : Uint256, domain_len : felt, domain : felt*, days : felt
):
    alloc_locals
    # # TODO : let time to stop front running

    # Verify that the starknet.id is owned by the caller
    let (caller) = get_caller_address()
    let (starknet_id_owner) = StarknetID.ownerOf(STARKNETID_CONTRACT, token_id)
    assert caller = starknet_id_owner

    # Verify that the domain is not registered already or expired
    let (current_timestamp) = get_block_timestamp()
    let (hashed_domain) = hash_domain(domain_len, domain)
    let (domain_data) = _domain_data.read(hashed_domain)
    let (is_expired) = is_le(domain_data.expiry, current_timestamp)

    if domain_data.owner.low != 0:
        assert is_expired = TRUE
    end

    if domain_data.owner.high != 0:
        assert is_expired = TRUE
    end

    # Get expiry and price
    let expiry = current_timestamp + 86400 * days  # # 1 day = 86400s
    let (erc20, price) = Pricing.compute_buy_price(PRICING_CONTRACT, domain[domain_len - 1], days)
    let data = DomainData(token_id, caller, expiry)

    # Register
    _register_domain(token_id, domain_len, domain, erc20, price, data, caller)

    ret
end

@external
func renew{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    token_id : Uint256, domain_len : felt, domain : felt*, days : felt
):
    alloc_locals

    # Verify that the domain is owned by the caller
    let (caller) = get_caller_address()
    let (starknetIdOwner) = StarknetID.ownerOf(STARKNETID_CONTRACT, token_id)
    assert caller = starknetIdOwner

    # Verify that the domain is not expired
    let (current_timestamp) = get_block_timestamp()
    let (hashed_domain) = hash_domain(domain_len, domain)
    let (domain_data) = _domain_data.read(hashed_domain)
    let (is_expired) = is_le(domain_data.expiry, current_timestamp)
    assert is_expired = FALSE

    # Get expiry and price
    let expiry = domain_data.expiry + 86400 * days  # # 1 day = 86400s
    let (erc20, price) = Pricing.compute_buy_price(PRICING_CONTRACT, domain[domain_len - 1], days)
    let data = DomainData(token_id, caller, expiry)

    # Register
    _register_domain(token_id, domain_len, domain, erc20, price, data, caller)

    ret
end

func _token_id_to_owner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    token_id : Uint256
) -> (owner_address : felt):
    let (owner_address) = StarknetID.ownerOf(STARKNETID_CONTRACT, token_id)

    return (owner_address)
end

func _register_domain{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    token_id : Uint256,
    domain_len : felt,
    domain : felt*,
    erc20 : felt,
    price : Uint256,
    data : DomainData,
    caller : felt,
):
    let (contract) = get_contract_address()

    # Make the user pay
    IERC20.transferFrom(erc20, caller, contract, price)

    # Write info on starknet.id and write info on storage data
    write_domain_data(domain_len, domain, data)
    write_address_to_domain(domain_len, domain, caller)
    StarknetID.set_verifier_data(STARKNETID_CONTRACT, token_id, 'name', domain[domain_len - 1])

    return ()
end

# ADMIN EXTERNAL FUNCTIONS

@external
func set_admin{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(address : felt):
    ret
end

@external
func set_domain_owner{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    domain_len : felt, domain : felt*, token_id : Uint256
):
    ret
end

@external
func set_pricing_implementation{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    address : felt
):
    ret
end

@external
func transfer_balance{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    erc20 : felt, amount : felt
):
    ret
end
