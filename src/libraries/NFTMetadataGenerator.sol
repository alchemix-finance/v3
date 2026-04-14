pragma solidity 0.8.28;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

library NFTMetadataGenerator {
    using Strings for uint256;

    // SVG colors
    string private constant SVG_BG_COLOR = "#1e1e1f";
    string private constant SVG_TEXT_COLOR = "#f5c09a";
    uint256 private constant TOKEN_ID_CHARS_PER_LINE = 25;
    uint256 private constant TOKEN_ID_LINE_HEIGHT = 22;
    uint256 private constant TOKEN_ID_FONT_SIZE = 30;
    uint256 private constant TOKEN_ID_START_Y = 250;

    /**
     * @notice Generate on-chain SVG for token
     * @param tokenId The token ID
     * @return SVG string
     */
    function generateSVG(uint256 tokenId, string memory title) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 500" width="500" height="500">',
                '<rect width="500" height="500" fill="',
                SVG_BG_COLOR,
                '" />',
                '<text x="250" y="190" font-family="monospace" font-size="34" fill="',
                SVG_TEXT_COLOR,
                '" text-anchor="middle">',
                title,
                "</text>",
                _generateTokenIdText(tokenId),
                _generateLogo(),
                "</svg>"
            )
        );
    }

    function _generateTokenIdText(uint256 tokenId) private pure returns (string memory) {
        bytes memory tokenIdBytes = bytes(string(abi.encodePacked("#", tokenId.toString())));
        uint256 lineCount = (tokenIdBytes.length + TOKEN_ID_CHARS_PER_LINE - 1) / TOKEN_ID_CHARS_PER_LINE;

        bytes memory output = abi.encodePacked(
            '<text x="250" y="',
            TOKEN_ID_START_Y.toString(),
            '" font-family="monospace" font-size="',
            TOKEN_ID_FONT_SIZE.toString(),
            '" fill="',
            SVG_TEXT_COLOR,
            '" text-anchor="middle">'
        );

        for (uint256 i = 0; i < lineCount; i++) {
            uint256 start = i * TOKEN_ID_CHARS_PER_LINE;
            uint256 end = start + TOKEN_ID_CHARS_PER_LINE;
            if (end > tokenIdBytes.length) {
                end = tokenIdBytes.length;
            }

            bytes memory line = new bytes(end - start);
            for (uint256 j = start; j < end; j++) {
                line[j - start] = tokenIdBytes[j];
            }

            output = abi.encodePacked(
                output,
                i == 0 ? '<tspan x="250">' : string(abi.encodePacked('<tspan x="250" dy="', TOKEN_ID_LINE_HEIGHT.toString(), '">')),
                line,
                "</tspan>"
            );
        }

        return string(abi.encodePacked(output, "</text>"));
    }

    function _generateLogo() private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<g transform="translate(135 414) scale(0.237)">',
                _generateLogoWordmark(),
                _generateLogoMark(),
                "</g>"
            )
        );
    }

    function _generateLogoWordmark() private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<rect x="614.1" y="48.9" width="63.9" height="16.1" fill="', SVG_TEXT_COLOR, '"/>',
                '<polygon points="672.9 89.3 614.1 89.3 614.1 105.4 665.3 105.4 672.9 89.3" fill="', SVG_TEXT_COLOR, '"/>',
                '<rect x="614.1" y="129.7" width="65.7" height="16.1" fill="', SVG_TEXT_COLOR, '"/>',
                '<path d="M251.3,49.1h-2.8l-42.2,96.8h16.6l9.6-23.3h33l9.2,23.3h18.8l-41.8-95.9-.4-.9ZM238.4,108l10.9-23.6,10.4,23.6h-21.3Z" fill="', SVG_TEXT_COLOR, '"/>',
                '<polygon points="332.8 48.7 316.4 48.7 316.4 145.9 379.5 145.9 379.5 129.8 332.8 129.8 332.8 48.7" fill="', SVG_TEXT_COLOR, '"/>',
                '<path d="M466,124.1c-2.2,1.8-5.1,3.4-8.7,4.8h0c-3.5,1.4-7.6,2.1-12.3,2.1s-12.2-1.5-16.9-4.3c-4.8-2.9-8.5-6.9-11.1-11.9-2.6-5.1-3.9-10.9-3.9-17.3s1.4-12.1,4.3-17.1c2.9-5.1,6.7-9.1,11.5-12.1,4.7-3,10-4.5,15.5-4.5s8.2.7,11.7,2.2c3.6,1.5,6.6,3.1,9,4.8l1.5,1.1,6.7-15.7-1.1-.7c-3.3-2.1-7.4-3.9-12.2-5.5-4.8-1.6-10.2-2.4-16.1-2.4s-13.4,1.3-19.3,3.8c-5.9,2.5-11,6.1-15.3,10.6-4.3,4.5-7.7,9.9-10,16-2.4,6.1-3.6,12.9-3.6,20.2s1.1,12.9,3.4,18.7c2.2,5.8,5.5,11.1,9.8,15.6,4.2,4.5,9.4,8.1,15.4,10.7,6,2.6,12.8,3.9,20.4,4,.4,0,.7,0,1.1,0,4.1,0,7.9-.5,11.4-1.4,3.8-1,7.1-2.2,9.9-3.6,2.8-1.4,5-2.6,6.5-3.5l1.1-.7-7.3-15.2-1.5,1.2Z" fill="', SVG_TEXT_COLOR, '"/>',
                '<polygon points="565.1 89.1 520.5 89.1 520.5 48.7 504.2 48.7 504.2 145.9 520.5 145.9 520.5 105.1 565.1 105.1 565.1 145.9 581.6 145.9 581.6 48.7 565.1 48.7 565.1 89.1" fill="', SVG_TEXT_COLOR, '"/>',
                '<polygon points="759.9 111.7 714.7 48.7 712.3 48.7 712.3 145.9 728.3 145.9 728.3 94.4 758.8 136.1 760.6 136.1 792 92.4 792 145.9 808.3 145.9 808.3 48.7 805.8 48.7 759.9 111.7" fill="', SVG_TEXT_COLOR, '"/>',
                '<rect x="839.8" y="48.9" width="16.3" height="97" fill="', SVG_TEXT_COLOR, '"/>',
                '<polygon points="935.2 96.8 965.6 48.9 945.8 48.9 926 82.6 904.3 48.9 883.8 48.9 914 96 882.5 145.9 902.6 145.9 923.3 110.6 946 145.9 966.9 145.9 935.2 96.8" fill="', SVG_TEXT_COLOR, '"/>'
            )
        );
    }

    function _generateLogoMark() private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<circle cx="92.5" cy="97.5" r="79.1" fill="none" stroke="', SVG_TEXT_COLOR, '" stroke-linecap="round" stroke-linejoin="round" stroke-width="5"/>',
                '<line x1="92.5" y1="120.4" x2="92.5" y2="176.6" fill="none" stroke="', SVG_TEXT_COLOR, '" stroke-linecap="round" stroke-linejoin="round" stroke-width="5"/>',
                '<line x1="92.5" y1="18.4" x2="92.5" y2="35" fill="none" stroke="', SVG_TEXT_COLOR, '" stroke-linecap="round" stroke-linejoin="round" stroke-width="5"/>',
                '<polyline points="92.5 120.4 38.6 77.7 92.5 35 146.4 77.7 122.3 96.8" fill="none" stroke="', SVG_TEXT_COLOR, '" stroke-linecap="round" stroke-linejoin="round" stroke-width="5"/>',
                '<polyline points="138.1 124.1 146.4 117.6 146.4 77.7" fill="none" stroke="', SVG_TEXT_COLOR, '" stroke-linecap="round" stroke-linejoin="round" stroke-width="5"/>',
                '<polyline points="38.6 77.7 38.6 117.6 92.5 160.3 116.8 141" fill="none" stroke="', SVG_TEXT_COLOR, '" stroke-linecap="round" stroke-linejoin="round" stroke-width="5"/>',
                '<polyline points="48 125.1 38.8 141 68.2 141" fill="none" stroke="', SVG_TEXT_COLOR, '" stroke-linecap="round" stroke-linejoin="round" stroke-width="5"/>',
                '<polyline points="92.5 141 146.2 141 92.5 48.1 64.4 96.6" fill="none" stroke="', SVG_TEXT_COLOR, '" stroke-linecap="round" stroke-linejoin="round" stroke-width="5"/>'
            )
        );
    }

    /**
     * @notice Generate the JSON string for the given token ID and SVG.
     * @param tokenId The token ID.
     * @param svg The SVG string.
     * @return The JSON string.
     */
    function generateJSONString(uint256 tokenId, string memory svg) internal pure returns (string memory) {
        string memory json = Base64.encode(
            abi.encodePacked(
                '{"name": "AlchemistV3 Position #',
                tokenId.toString(),
                '", ',
                '"description": "Position token for Alchemist V3", ',
                '"image": "data:image/svg+xml;base64,',
                Base64.encode(bytes(svg)),
                '"}'
            )
        );
        return json;
    }

    /**
     * @notice Generate the token URI for the given token ID and title.
     * @param tokenId The token ID.
     * @param title The title of the token.
     * @return The full token URI with data.
     */
    function generateTokenURI(uint256 tokenId, string memory title) internal pure returns (string memory) {
        string memory svg = generateSVG(tokenId, title);
        string memory json = generateJSONString(tokenId, svg);
        return string(abi.encodePacked("data:application/json;base64,", json));
    }
}
