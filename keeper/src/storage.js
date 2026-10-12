export const EIP1967_IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

function slotHex(value) {
  return `0x${value.toString(16)}`;
}

export function addressFromStorageWord(word) {
  return `0x${word.slice(-40)}`;
}

export async function getProxyImplementation(web3, proxyAddress) {
  const word = await web3.eth.getStorageAt(proxyAddress, EIP1967_IMPLEMENTATION_SLOT);
  return web3.utils.toChecksumAddress(addressFromStorageWord(word));
}

export function accountBaseSlot(web3, tokenId, mappingSlot) {
  const encoded = web3.eth.abi.encodeParameters(
    ["uint256", "uint256"],
    [BigInt(tokenId).toString(), BigInt(mappingSlot).toString()],
  );
  return BigInt(web3.utils.keccak256(encoded));
}

export async function readStoredDebt(web3, alchemistAddress, tokenId, mappingSlot, blockNumber = "latest") {
  const debtSlot = accountBaseSlot(web3, tokenId, mappingSlot) + 1n;
  const word = await web3.eth.getStorageAt(alchemistAddress, slotHex(debtSlot), blockNumber);
  return BigInt(word);
}
