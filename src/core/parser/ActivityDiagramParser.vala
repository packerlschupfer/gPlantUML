namespace GPlantUML {
    public class ActivityDiagramParser : Object {
        private Gee.ArrayList<Token> tokens;
        private int current;
        private ActivityDiagram diagram;
        private ActivityNode? last_node;
        private Gee.ArrayList<ActivityNode> pending_connections;
        private string? current_partition;
        private string? pending_edge_label;
        private string? pending_edge_color;
        private string? pending_edge_style;
        private EdgeDirection pending_edge_direction;
        private string? pending_edge_note;
        private Gee.HashMap<string, ActivityNode> connectors;
        private Gee.ArrayList<ActivityNode> pending_breaks;

        public ActivityDiagramParser() {
            this.current = 0;
            this.pending_connections = new Gee.ArrayList<ActivityNode>();
            this.current_partition = null;
            this.pending_edge_label = null;
            this.pending_edge_color = null;
            this.pending_edge_style = null;
            this.pending_edge_direction = EdgeDirection.DEFAULT;
            this.pending_edge_note = null;
            this.connectors = new Gee.HashMap<string, ActivityNode>();
            this.pending_breaks = new Gee.ArrayList<ActivityNode>();
        }

        public ActivityDiagram parse(Gee.ArrayList<Token> tokens) {
            this.tokens = tokens;
            this.current = 0;
            this.diagram = new ActivityDiagram();
            this.last_node = null;
            this.pending_connections.clear();
            this.current_partition = null;
            this.pending_edge_label = null;
            this.pending_edge_color = null;
            this.pending_edge_style = null;
            this.pending_edge_direction = EdgeDirection.DEFAULT;
            this.pending_edge_note = null;
            this.connectors.clear();
            this.pending_breaks.clear();

            try {
                parse_diagram();
            } catch (Error e) {
                diagram.errors.add(new ParseError(e.message, 1, 1));
            }

            return diagram;
        }

        private void parse_diagram() throws Error {
            skip_newlines();

            // Skip @startuml and any diagram name after it
            if (match(TokenType.STARTUML)) {
                // Skip diagram name if present (e.g., @startuml DiagramName)
                while (!check(TokenType.NEWLINE) && !is_at_end()) {
                    advance();
                }
                skip_newlines();
            }

            // Parse statements until @enduml with iteration limit
            int max_iterations = tokens.size * 2;
            int iterations = 0;

            while (!check(TokenType.ENDUML) && !is_at_end() && iterations < max_iterations) {
                int pos_before = current;
                try {
                    parse_statement();
                } catch (Error e) {
                    diagram.errors.add(new ParseError(
                        e.message,
                        previous().line,
                        previous().column
                    ));
                    synchronize();
                }
                skip_newlines();
                iterations++;

                // Safety: if we didn't advance, force advance to prevent infinite loop
                if (current == pos_before && !is_at_end()) {
                    advance();
                }
            }
        }

        private void parse_statement() throws Error {
            skip_newlines();

            if (is_at_end() || check(TokenType.ENDUML)) {
                return;
            }

            // Skip comments
            if (match(TokenType.COMMENT)) {
                return;
            }

            // Start node
            if (match(TokenType.START)) {
                var node = new ActivityNode(ActivityNodeType.START, null, previous().line);
                add_node_with_connection(node);
                return;
            }

            // Stop node
            if (match(TokenType.STOP)) {
                var node = new ActivityNode(ActivityNodeType.STOP, null, previous().line);
                add_node_with_connection(node);
                last_node = null; // Nothing follows stop
                return;
            }

            // Kill - terminates flow with X symbol
            if (match(TokenType.KILL)) {
                var node = new ActivityNode(ActivityNodeType.KILL, null, previous().line);
                add_node_with_connection(node);
                last_node = null;
                return;
            }

            // End (but not "end fork", "end merge", "end split", etc.)
            if (check(TokenType.END) && !check_next(TokenType.FORK) && !check_next(TokenType.MERGE) && !check_next(TokenType.SPLIT) && !check_next(TokenType.NOTE)) {
                advance();  // consume END
                var node = new ActivityNode(ActivityNodeType.END, null, previous().line);
                add_node_with_connection(node);
                last_node = null;
                return;
            }

            // Detach - flow ends invisibly
            if (match(TokenType.DETACH)) {
                var node = new ActivityNode(ActivityNodeType.DETACH, null, previous().line);
                add_node_with_connection(node);
                last_node = null;
                return;
            }

            // Break - exits the current loop
            if (match(TokenType.BREAK)) {
                var break_node = new ActivityNode(ActivityNodeType.ACTION, "break", previous().line);
                add_node_with_connection(break_node);
                pending_breaks.add(break_node);
                last_node = null;  // Flow stops here, will connect to loop exit
                return;
            }

            // Arrow with label: -> label; or styled arrow: -[#color]-> label;
            if (match(TokenType.ARROW_RIGHT) || match(TokenType.ARROW_RIGHT_DOTTED) ||
                match(TokenType.ARROW_LEFT) || match(TokenType.ARROW_LEFT_DOTTED)) {
                parse_arrow_label();
                return;
            }

            // Styled arrow: -[#color]-> or -[dashed]-> or direction arrow: -up->
            if (check(TokenType.MINUS)) {
                if (check_next(TokenType.LBRACKET)) {
                    parse_styled_arrow();
                    return;
                }
                // Check for direction arrow: -up->, -down->, -left->, -right->
                if (check_next(TokenType.IDENTIFIER)) {
                    string next_lexeme = tokens.get(current + 1).lexeme.down();
                    if (next_lexeme == "up" || next_lexeme == "u" ||
                        next_lexeme == "down" || next_lexeme == "d" ||
                        next_lexeme == "left" || next_lexeme == "l" ||
                        next_lexeme == "right" || next_lexeme == "r") {
                        parse_styled_arrow();
                        return;
                    }
                }
            }

            // Colored action (starts with #color:)
            if (match(TokenType.HASH)) {
                parse_colored_action(previous().line);
                return;
            }

            // Action (starts with colon)
            if (match(TokenType.COLON)) {
                parse_action(null, null, null, null, previous().line);
                return;
            }

            // If statement
            if (match(TokenType.IF)) {
                parse_if(previous().line);
                return;
            }

            // Fork (but not "fork again" which is handled by parse_fork's loop)
            if (check(TokenType.FORK) && !check_fork_again()) {
                int fork_line = advance().line;  // consume FORK
                parse_fork(fork_line);
                return;
            }

            // While loop
            if (match(TokenType.WHILE)) {
                parse_while(previous().line);
                return;
            }

            // Repeat loop
            if (match(TokenType.REPEAT)) {
                parse_repeat(previous().line);
                return;
            }

            // Switch/case
            if (match(TokenType.SWITCH)) {
                parse_switch(previous().line);
                return;
            }

            // Split (non-synchronizing parallel)
            if (match(TokenType.SPLIT)) {
                parse_split(previous().line);
                return;
            }

            // Swimlane syntax: |Name|
            if (match(TokenType.PIPE)) {
                parse_swimlane();
                return;
            }

            // Partition syntax: partition "Name" { ... }
            if (match(TokenType.PARTITION)) {
                parse_partition();
                return;
            }

            // Group syntax: group Name ... end group
            if (match(TokenType.GROUP)) {
                parse_group();
                return;
            }

            // Note (or floating note)
            if (match(TokenType.FLOATING)) {
                // floating note - must be followed by NOTE
                if (match(TokenType.NOTE)) {
                    parse_note(true);  // true = floating
                }
                return;
            }
            if (match(TokenType.NOTE)) {
                parse_note(false);  // false = attached
                return;
            }

            // Connector: (A) for goto labels
            if (match(TokenType.LPAREN)) {
                parse_connector(previous().line);
                return;
            }

            // Title
            if (match(TokenType.TITLE)) {
                parse_title();
                return;
            }

            // Header
            if (match(TokenType.HEADER)) {
                parse_header();
                return;
            }

            // Footer
            if (match(TokenType.FOOTER)) {
                parse_footer();
                return;
            }

            // Caption
            if (match(TokenType.CAPTION)) {
                parse_caption();
                return;
            }

            // Horizontal separator ==== or == text ==
            if (match(TokenType.SEPARATOR)) {
                int sep_line = previous().line;
                // Check for optional label after ====
                var node = new ActivityNode(ActivityNodeType.SEPARATOR, null, sep_line);
                if (!check(TokenType.NEWLINE) && !check(TokenType.SEPARATOR) && !is_at_end()) {
                    var sb = new StringBuilder();
                    while (!check(TokenType.SEPARATOR) && !check(TokenType.NEWLINE) && !is_at_end()) {
                        if (sb.len > 0) sb.append(" ");
                        sb.append(advance().lexeme);
                    }
                    match(TokenType.SEPARATOR);  // consume closing ====
                    node.label = sb.str.strip();
                }
                add_node_with_connection(node);
                return;
            }

            // Separator with text: == text == (2 equals on each side)
            if (check(TokenType.IDENTIFIER) && peek().lexeme == "=") {
                if (current + 1 < tokens.size && tokens.get(current + 1).lexeme == "=") {
                    int eq_line = advance().line;  // first =
                    advance();  // second =
                    var sb = new StringBuilder();
                    while (!is_at_end() && !check(TokenType.NEWLINE)) {
                        Token t = peek();
                        // Check for closing ==
                        if (t.lexeme == "=" && current + 1 < tokens.size &&
                            tokens.get(current + 1).lexeme == "=") {
                            advance();  // first closing =
                            advance();  // second closing =
                            break;
                        }
                        if (sb.len > 0) sb.append(" ");
                        sb.append(advance().lexeme);
                    }
                    var node = new ActivityNode(ActivityNodeType.SEPARATOR, sb.str.strip(), eq_line);
                    add_node_with_connection(node);
                    return;
                }
            }

            // Vertical space |||
            if (match(TokenType.VSPACE)) {
                var node = new ActivityNode(ActivityNodeType.VSPACE, null, previous().line);
                add_node_with_connection(node);
                return;
            }

            // Skinparam - skip (styling not fully implemented)
            if (match(TokenType.SKINPARAM)) {
                parse_skinparam();
                return;
            }

            // Scale directive - skip rest of line
            if (match(TokenType.SCALE)) {
                while (!check(TokenType.NEWLINE) && !is_at_end()) {
                    advance();
                }
                return;
            }

            // Hide/show directives - skip rest of line
            if (match(TokenType.HIDE) || match(TokenType.SHOW)) {
                while (!check(TokenType.NEWLINE) && !is_at_end()) {
                    advance();
                }
                return;
            }

            // Legend
            if (match(TokenType.LEGEND)) {
                parse_legend();
                return;
            }

            // Unknown - skip
            advance();
        }

        private void parse_skinparam() throws Error {
            // Parse skinparam directives and store in diagram.skin_params
            // Single line: skinparam PropertyName value
            // Single line with element: skinparam elementPropertyName value
            // Block: skinparam element { PropertyName value ... }

            // Get the first identifier (could be element name or property name)
            // Note: element names like "class", "state", "component" are keywords, not identifiers
            string first_name = "";
            if (check(TokenType.IDENTIFIER) || is_skinparam_element_keyword()) {
                first_name = advance().lexeme;
            } else {
                // No identifier after skinparam - skip line
                skip_to_end_of_line();
                return;
            }

            // Check if this is block syntax
            if (match(TokenType.LBRACE)) {
                // Block syntax: skinparam element { property value ... }
                string element = first_name;
                parse_skinparam_block(element);
            } else {
                // Single line syntax
                // Could be: skinparam PropertyName value
                // Or: skinparam elementPropertyName value (combined like "componentBackgroundColor")
                string value = collect_skinparam_value();
                if (value.length > 0) {
                    // Store as global property (parser doesn't split combined names)
                    diagram.skin_params.set_global(first_name, value);
                }
            }
        }

        private void parse_skinparam_block(string element) throws Error {
            // Parse block: { PropertyName value \n PropertyName value \n ... }
            skip_newlines();

            while (!check(TokenType.RBRACE) && !is_at_end()) {
                skip_newlines();

                if (check(TokenType.RBRACE)) {
                    break;
                }

                // Get property name
                if (!check(TokenType.IDENTIFIER)) {
                    advance();  // Skip unknown token
                    continue;
                }

                string property = advance().lexeme;

                // Get value (rest of line until newline)
                string value = collect_skinparam_value();

                if (value.length > 0) {
                    diagram.skin_params.set_element_property(element, property, value);
                }

                skip_newlines();
            }

            match(TokenType.RBRACE);  // Consume closing brace
        }

        private string collect_skinparam_value() {
            // Collect value tokens until newline or closing brace
            // Colors like #1e1e1e are tokenized as # + 1 + e1e1e, so we need to join without spaces
            // when the previous token was # or when we're in the middle of a color
            var sb = new StringBuilder();
            bool in_color = false;

            while (!check(TokenType.NEWLINE) && !check(TokenType.RBRACE) && !is_at_end()) {
                Token t = advance();

                // Check if this is a hash starting a color
                if (t.lexeme == "#") {
                    if (sb.len > 0) {
                        sb.append(" ");
                    }
                    sb.append(t.lexeme);
                    in_color = true;
                } else if (in_color) {
                    // Continue collecting color without spaces until we hit a non-hex character
                    // Hex colors are 3-8 hex chars (3, 4, 6, or 8)
                    sb.append(t.lexeme);
                    // Check if this looks like the end of a color (next token would be space or non-hex)
                    if (!check(TokenType.IDENTIFIER) && !check(TokenType.HASH)) {
                        in_color = false;
                    }
                } else {
                    // Regular token - add space separator
                    if (sb.len > 0) {
                        sb.append(" ");
                    }
                    sb.append(t.lexeme);
                }
            }

            return sb.str.strip();
        }

        private void skip_to_end_of_line() {
            while (!check(TokenType.NEWLINE) && !is_at_end()) {
                advance();
            }
        }

        private bool is_skinparam_element_keyword() {
            // Keywords that can be used as skinparam element names
            switch (peek().token_type) {
                case TokenType.CLASS:
                case TokenType.INTERFACE:
                case TokenType.ABSTRACT:
                case TokenType.ENUM:
                case TokenType.NOTE:
                case TokenType.LEGEND:
                case TokenType.TITLE:
                case TokenType.HEADER:
                case TokenType.FOOTER:
                case TokenType.PARTICIPANT:
                case TokenType.ACTOR:
                case TokenType.BOUNDARY:
                case TokenType.CONTROL:
                case TokenType.ENTITY:
                case TokenType.DATABASE:
                    return true;
                default:
                    return false;
            }
        }

        private void parse_arrow_label() throws Error {
            // Collect label until semicolon or newline
            var sb = new StringBuilder();

            while (!check(TokenType.SEMICOLON) && !check(TokenType.NEWLINE) && !is_at_end()) {
                Token t = advance();
                if (sb.len > 0) {
                    sb.append(" ");
                }
                sb.append(t.lexeme);
            }

            match(TokenType.SEMICOLON);

            string label = sb.str.strip();
            if (label.length > 0) {
                pending_edge_label = label;
            }
        }

        private void parse_styled_arrow() throws Error {
            // Parse: -[#color]-> or -[dashed]-> or -[#color,dashed]-> or -up-> or -down->
            advance();  // consume -

            string? color = null;
            string? style = null;
            EdgeDirection direction = EdgeDirection.DEFAULT;

            // Check if this is a direction arrow (-up->, -down->, etc.) or styled arrow (-[...]->)
            if (check(TokenType.LBRACKET)) {
                advance();  // consume [

                // Parse style content until ]
                var style_parts = new Gee.ArrayList<string>();
                var current_part = new StringBuilder();

                while (!check(TokenType.RBRACKET) && !is_at_end()) {
                    Token t = advance();
                    if (t.lexeme == ",") {
                        if (current_part.len > 0) {
                            style_parts.add(current_part.str.strip());
                            current_part = new StringBuilder();
                        }
                    } else {
                        current_part.append(t.lexeme);
                    }
                }
                if (current_part.len > 0) {
                    style_parts.add(current_part.str.strip());
                }

                match(TokenType.RBRACKET);

                // Process style parts - collect ALL colors for multi-line arrows
                var colors = new Gee.ArrayList<string>();
                foreach (var part in style_parts) {
                    // Handle semicolon-separated values (e.g., #red;#green;#orange;#blue)
                    // PlantUML renders these as multiple parallel arrows
                    string[] subparts = part.split(";");
                    foreach (var subpart in subparts) {
                        string trimmed = subpart.strip();
                        if (trimmed.length == 0) continue;

                        string lower = trimmed.down();
                        if (trimmed.has_prefix("#")) {
                            // Convert #colorname to colorname, keep #RRGGBB as is
                            string color_part = trimmed.substring(1);
                            string color_lower = color_part.down();
                            // Check if it's actually a style keyword with # prefix (user error)
                            if (color_lower == "dashed" || color_lower == "dotted" ||
                                color_lower == "bold" || color_lower == "hidden") {
                                if (style == null) {
                                    style = color_lower;
                                }
                            } else {
                                // Collect all colors for multi-arrow support
                                if (color_part.length == 6 && is_hex_color(color_part)) {
                                    colors.add(trimmed);  // Keep #RRGGBB
                                } else {
                                    colors.add(color_part);  // Use colorname without #
                                }
                            }
                        } else if (lower == "up" || lower == "u") {
                            direction = EdgeDirection.UP;
                        } else if (lower == "down" || lower == "d") {
                            direction = EdgeDirection.DOWN;
                        } else if (lower == "left" || lower == "l") {
                            direction = EdgeDirection.LEFT;
                        } else if (lower == "right" || lower == "r") {
                            direction = EdgeDirection.RIGHT;
                        } else if (lower == "dashed" || lower == "dotted" || lower == "bold" || lower == "hidden") {
                            if (style == null) {  // Take first style only
                                style = lower;
                            }
                        } else {
                            // Treat as color - Graphviz supports many color names
                            colors.add(lower);
                        }
                    }
                }
                // Join colors with semicolon for multi-arrow rendering
                if (colors.size > 0) {
                    color = string.joinv(";", colors.to_array());
                }
            } else {
                // Direction arrow: -up->, -down->, -left->, -right->
                if (check(TokenType.IDENTIFIER)) {
                    string dir = peek().lexeme.down();
                    if (dir == "up" || dir == "u") {
                        direction = EdgeDirection.UP;
                        advance();
                    } else if (dir == "down" || dir == "d") {
                        direction = EdgeDirection.DOWN;
                        advance();
                    } else if (dir == "left" || dir == "l") {
                        direction = EdgeDirection.LEFT;
                        advance();
                    } else if (dir == "right" || dir == "r") {
                        direction = EdgeDirection.RIGHT;
                        advance();
                    }
                }
            }

            // Parse the rest of the arrow (-> or -->)
            while (!check(TokenType.SEMICOLON) && !check(TokenType.NEWLINE) &&
                   !check(TokenType.COLON) && !is_at_end()) {
                Token t = peek();
                // Stop when we hit something that's not part of the arrow
                if (t.token_type == TokenType.IDENTIFIER && t.lexeme != ">") {
                    break;
                }
                advance();
            }

            pending_edge_color = color;
            pending_edge_style = style;
            pending_edge_direction = direction;

            // Check for optional label after arrow
            if (!check(TokenType.SEMICOLON) && !check(TokenType.NEWLINE) && !is_at_end()) {
                var sb = new StringBuilder();
                while (!check(TokenType.SEMICOLON) && !check(TokenType.NEWLINE) && !is_at_end()) {
                    Token t = advance();
                    if (sb.len > 0) {
                        sb.append(" ");
                    }
                    sb.append(t.lexeme);
                }
                string label = sb.str.strip();
                if (label.length > 0) {
                    pending_edge_label = label;
                }
            }

            match(TokenType.SEMICOLON);
        }

        private void parse_colored_action(int source_line) throws Error {
            // Parse: #color:action text; or #color1/color2:action text; (gradient)
            // Also: #color;line:border_color:action text;
            // Also: #color;text:font_color:action text;
            var color_sb = new StringBuilder();
            string? color = null;
            string? color2 = null;
            string? line_color = null;
            string? text_color = null;

            // Collect tokens until we find the final colon before action
            // Handle line:color and text:color specifiers
            while (!is_at_end() && !check(TokenType.NEWLINE)) {
                if (check(TokenType.COLON)) {
                    // Check what comes before this colon
                    string current = color_sb.str.strip();

                    if (current.has_suffix("line")) {
                        // Consume colon and get line color
                        advance();
                        var val_sb = new StringBuilder();
                        while (!check(TokenType.COLON) && !check(TokenType.SEMICOLON) &&
                               !check(TokenType.NEWLINE) && !is_at_end()) {
                            val_sb.append(advance().lexeme);
                        }
                        line_color = val_sb.str.strip();
                        // Remove "line" from color_sb
                        string before = current.substring(0, current.length - 4).strip();
                        if (before.has_suffix(";")) {
                            before = before.substring(0, before.length - 1).strip();
                        }
                        color_sb = new StringBuilder();
                        color_sb.append(before);

                        // Skip semicolon if present
                        if (check(TokenType.SEMICOLON)) {
                            advance();
                        }
                    } else if (current.has_suffix("text")) {
                        // Consume colon and get text color
                        advance();
                        var val_sb = new StringBuilder();
                        while (!check(TokenType.COLON) && !check(TokenType.SEMICOLON) &&
                               !check(TokenType.NEWLINE) && !is_at_end()) {
                            val_sb.append(advance().lexeme);
                        }
                        text_color = val_sb.str.strip();
                        // Remove "text" from color_sb
                        string before = current.substring(0, current.length - 4).strip();
                        if (before.has_suffix(";")) {
                            before = before.substring(0, before.length - 1).strip();
                        }
                        color_sb = new StringBuilder();
                        color_sb.append(before);

                        // Skip semicolon if present
                        if (check(TokenType.SEMICOLON)) {
                            advance();
                        }
                    } else {
                        // This is the colon before action text
                        break;
                    }
                } else {
                    color_sb.append(advance().lexeme);
                }
            }

            string color_str = color_sb.str.strip();

            // Parse background color (may be gradient)
            if (color_str.length > 0) {
                int sep_idx = color_str.index_of("/");
                if (sep_idx == -1) {
                    sep_idx = color_str.index_of("\\");
                }

                if (sep_idx > 0 && sep_idx < color_str.length - 1) {
                    color = color_str.substring(0, sep_idx).strip();
                    color2 = color_str.substring(sep_idx + 1).strip();
                } else {
                    color = color_str;
                }
            }

            // Expect colon before action text
            if (match(TokenType.COLON)) {
                parse_action(color, color2, line_color, text_color, source_line);
            }
        }

        private void parse_action(string? color, string? color2, string? line_color, string? text_color, int source_line) throws Error {
            // Collect text until semicolon (can span multiple lines)
            // Pipe character | is used as line separator: :line1|line2|line3;
            var sb = new StringBuilder();
            int url_bracket_depth = 0;  // Track if we're inside [[...]]

            while (!check(TokenType.SEMICOLON) && !is_at_end()) {
                Token t = advance();
                if (t.token_type == TokenType.NEWLINE) {
                    // Preserve newlines in multi-line actions
                    sb.append("\n");
                } else if (t.token_type == TokenType.PIPE) {
                    // Pipe is line separator in actions: :line1|line2;
                    sb.append("\n");
                } else {
                    // Track URL bracket depth: [[ opens, ]] closes
                    if (t.lexeme == "[" && sb.str.has_suffix("[")) {
                        url_bracket_depth++;
                    } else if (t.lexeme == "]" && sb.str.has_suffix("]") && url_bracket_depth > 0) {
                        url_bracket_depth--;
                    }

                    // Check if this is an escape sequence (like \n, \t)
                    bool is_escape_seq = t.lexeme.has_prefix("\\") && t.lexeme.length == 2;
                    // Check if previous content ends with escape sequence start
                    bool prev_ends_with_escape = sb.str.has_suffix("\\");

                    // Check for Creole formatting markers - don't add spaces around them
                    bool is_creole_marker = t.lexeme == "*" || t.lexeme == "/" ||
                                            t.lexeme == "_" || t.lexeme == "-" || t.lexeme == "~";
                    bool prev_ends_with_creole = sb.str.has_suffix("*") || sb.str.has_suffix("/") ||
                                                  sb.str.has_suffix("_") || sb.str.has_suffix("-") ||
                                                  sb.str.has_suffix("~");

                    // Check for URL brackets - only skip space when forming [[ or ]]
                    bool is_double_open = t.lexeme == "[" && sb.str.has_suffix("[");
                    bool is_double_close = t.lexeme == "]" && sb.str.has_suffix("]");

                    // Inside URL brackets, don't add spaces around URL-forming characters
                    bool is_url_char = t.lexeme == ":" || t.lexeme == "/" || t.lexeme == "." ||
                                       t.lexeme == "-" || t.lexeme == "_" || t.lexeme == "?" ||
                                       t.lexeme == "=" || t.lexeme == "&" || t.lexeme == "#";
                    bool prev_ends_with_url_char = sb.str.has_suffix(":") || sb.str.has_suffix("/") ||
                                                    sb.str.has_suffix(".") || sb.str.has_suffix("-") ||
                                                    sb.str.has_suffix("?") || sb.str.has_suffix("=") ||
                                                    sb.str.has_suffix("&") || sb.str.has_suffix("#") ||
                                                    sb.str.has_suffix("[");

                    // Determine if we should skip adding a space
                    bool skip_space = is_escape_seq || prev_ends_with_escape
                                      || is_creole_marker || prev_ends_with_creole
                                      || is_double_open || is_double_close;

                    // Inside URL brackets, also skip spaces around URL characters and before ]
                    if (url_bracket_depth > 0 && (is_url_char || prev_ends_with_url_char || t.lexeme == "]")) {
                        skip_space = true;
                    }

                    // Skip spaces around UTF-8 continuation bytes (lexer may tokenize them separately)
                    // UTF-8 lead bytes are >= 0xC0, continuation bytes are 0x80-0xBF
                    bool is_utf8_byte = false;
                    if (t.lexeme.length == 1) {
                        uint8 b = (uint8)t.lexeme[0];
                        is_utf8_byte = b >= 0x80;  // Any high byte
                    }
                    bool prev_ends_with_utf8 = false;
                    if (sb.len > 0) {
                        uint8 last_b = (uint8)sb.str[sb.len - 1];
                        prev_ends_with_utf8 = last_b >= 0x80;
                    }
                    if (is_utf8_byte || prev_ends_with_utf8) {
                        skip_space = true;
                    }

                    if (sb.len > 0 && !sb.str.has_suffix("\n") && t.token_type != TokenType.COLON
                        && !skip_space) {
                        sb.append(" ");
                    }
                    sb.append(t.lexeme);
                }
            }

            match(TokenType.SEMICOLON);

            string text = sb.str.strip();
            string? stereotype = null;
            ActionShape shape = ActionShape.DEFAULT;

            // Check for stereotype AFTER semicolon: :action; <<stereotype>>
            if (!is_at_end() && peek().lexeme == "<" && check_next_lexeme("<")) {
                advance();  // consume first <
                advance();  // consume second <
                var st_sb = new StringBuilder();
                while (!is_at_end() && !(peek().lexeme == ">" && check_next_lexeme(">"))) {
                    st_sb.append(advance().lexeme);
                }
                if (!is_at_end() && peek().lexeme == ">") {
                    advance();  // consume first >
                    if (!is_at_end() && peek().lexeme == ">") {
                        advance();  // consume second >
                    }
                }
                stereotype = st_sb.str.strip();

                // Check for SDL stereotypes and set shape (don't display these as text)
                string st_lower = stereotype.down();
                if (st_lower == "input") {
                    shape = ActionShape.SDL_INPUT;
                    stereotype = null;  // SDL shapes don't show stereotype text
                } else if (st_lower == "output") {
                    shape = ActionShape.SDL_OUTPUT;
                    stereotype = null;
                } else if (st_lower == "procedure" || st_lower == "subprocess") {
                    shape = ActionShape.SDL_PROCEDURE;
                    stereotype = null;
                } else if (st_lower == "save") {
                    shape = ActionShape.SDL_SAVE;
                    stereotype = null;
                } else if (st_lower == "load") {
                    shape = ActionShape.SDL_LOAD;
                    stereotype = null;
                } else if (st_lower == "task") {
                    shape = ActionShape.SDL_TASK;
                    stereotype = null;
                }
            }

            // Also check for stereotype at START of text: <<text>> action
            if (stereotype == null && (text.has_prefix("< <") || text.has_prefix("<<"))) {
                int start_idx = text.has_prefix("<<") ? 2 : 3;
                int end_idx = text.index_of("> >");
                if (end_idx == -1) {
                    end_idx = text.index_of(">>");
                }
                if (end_idx > start_idx) {
                    stereotype = text.substring(start_idx, end_idx - start_idx).strip();
                    // Remove stereotype from text
                    int text_start = end_idx + (text.substring(end_idx).has_prefix(">>") ? 2 : 3);
                    text = text.substring(text_start).strip();

                    // Check for SDL stereotypes and set shape (don't display these as text)
                    string st_lower = stereotype.down();
                    if (st_lower == "input") {
                        shape = ActionShape.SDL_INPUT;
                        stereotype = null;
                    } else if (st_lower == "output") {
                        shape = ActionShape.SDL_OUTPUT;
                        stereotype = null;
                    } else if (st_lower == "procedure" || st_lower == "subprocess") {
                        shape = ActionShape.SDL_PROCEDURE;
                        stereotype = null;
                    } else if (st_lower == "save") {
                        shape = ActionShape.SDL_SAVE;
                        stereotype = null;
                    } else if (st_lower == "load") {
                        shape = ActionShape.SDL_LOAD;
                        stereotype = null;
                    } else if (st_lower == "task") {
                        shape = ActionShape.SDL_TASK;
                        stereotype = null;
                    }
                }
            }

            // Check for SDL shapes: |text|, <text>, >text>, /text/, ]text]
            if (text.has_prefix("|") && text.has_suffix("|") && text.length > 2) {
                shape = ActionShape.SDL_TASK;
                text = text.substring(1, text.length - 2).strip();
            } else if (text.has_prefix("<") && text.has_suffix(">") && text.length > 2) {
                shape = ActionShape.SDL_INPUT;
                text = text.substring(1, text.length - 2).strip();
            } else if (text.has_prefix(">") && text.has_suffix(">") && text.length > 2) {
                shape = ActionShape.SDL_OUTPUT;
                text = text.substring(1, text.length - 2).strip();
            } else if (text.has_prefix("/") && text.has_suffix("/") && text.length > 2
                       && !text.has_prefix("//")) {
                // SDL_SAVE: /text/ but NOT //text// (which is Creole italic)
                shape = ActionShape.SDL_SAVE;
                text = text.substring(1, text.length - 2).strip();
            } else if (text.has_prefix("]") && text.has_suffix("]") && text.length > 2) {
                shape = ActionShape.SDL_PROCEDURE;
                text = text.substring(1, text.length - 2).strip();
            }

            // Check for URL: [[url text]] or [[url]]
            string? url = null;
            if (text.contains("[[") && text.contains("]]")) {
                int url_start = text.index_of("[[");
                int url_end = text.index_of("]]");
                if (url_end > url_start + 2) {
                    string url_content = text.substring(url_start + 2, url_end - url_start - 2).strip();
                    // Check for "url text" format (space separates url from display text)
                    int space_idx = url_content.index_of(" ");
                    string display_text;
                    if (space_idx > 0) {
                        url = url_content.substring(0, space_idx).strip();
                        display_text = url_content.substring(space_idx + 1).strip();
                    } else {
                        url = url_content;
                        display_text = url_content;
                    }
                    // Replace [[...]] with display text
                    text = text.substring(0, url_start) + display_text + text.substring(url_end + 2);
                    text = text.strip();
                }
            }

            var node = new ActivityNode(ActivityNodeType.ACTION, text, source_line);
            node.color = color;
            node.color2 = color2;
            node.line_color = line_color;
            node.text_color = text_color;
            node.stereotype = stereotype;
            node.url = url;
            node.shape = shape;
            add_node_with_connection(node);
        }

        private void parse_if(int source_line) throws Error {
            // Track all branch ends for connecting to merge
            var branch_ends = new Gee.ArrayList<ActivityNode>();

            // Check for optional color: if (#color) (condition)
            string? if_color = null;
            if (match(TokenType.LPAREN)) {
                if (check(TokenType.HASH)) {
                    advance();  // consume #
                    var color_sb = new StringBuilder();
                    while (!check(TokenType.RPAREN) && !is_at_end()) {
                        color_sb.append(advance().lexeme);
                    }
                    match(TokenType.RPAREN);
                    if_color = color_sb.str.strip();
                    // Now parse the actual condition
                    if (match(TokenType.LPAREN)) {
                        // condition follows
                    }
                }
            }

            // Parse first condition
            string condition = "";
            if (previous().token_type == TokenType.LPAREN || match(TokenType.LPAREN)) {
                condition = consume_until_rparen();
            }

            var cond_node = new ActivityNode(ActivityNodeType.CONDITION, condition, source_line);
            cond_node.color = if_color;
            add_node_with_connection(cond_node);

            // Parse 'then' branch label
            string yes_label = "yes";
            skip_newlines();
            if (match(TokenType.THEN)) {
                if (match(TokenType.LPAREN)) {
                    yes_label = consume_until_rparen();
                }
            }
            cond_node.condition_yes = yes_label;

            // Parse 'then' branch statements
            skip_newlines();
            last_node = cond_node;

            while (!check(TokenType.ELSE) && !check(TokenType.ELSEIF) &&
                   !check(TokenType.ENDIF) && !is_at_end()) {
                parse_statement();
                skip_newlines();
            }

            // Mark the yes branch edge
            foreach (var edge in diagram.edges) {
                if (edge.from == cond_node) {
                    edge.label = yes_label;
                    edge.is_yes_branch = true;
                    break;
                }
            }

            if (last_node != null && last_node != cond_node) {
                branch_ends.add(last_node);
            }

            // Track last condition for chaining elseif/else
            ActivityNode last_cond = cond_node;

            // Parse 'elseif' branches
            while (match(TokenType.ELSEIF)) {
                int elseif_line = previous().line;
                string elseif_cond = "";
                if (match(TokenType.LPAREN)) {
                    elseif_cond = consume_until_rparen();
                }

                var elseif_node = new ActivityNode(ActivityNodeType.CONDITION, elseif_cond, elseif_line);
                diagram.add_node(elseif_node);

                // Connect from previous condition's "no" branch
                var no_edge = new ActivityEdge(last_cond, elseif_node, last_cond.condition_no);
                no_edge.is_no_branch = true;
                diagram.add_edge(no_edge);

                // Parse 'then' label for elseif
                string elseif_yes = "yes";
                skip_newlines();
                if (match(TokenType.THEN)) {
                    if (match(TokenType.LPAREN)) {
                        elseif_yes = consume_until_rparen();
                    }
                }
                elseif_node.condition_yes = elseif_yes;

                // Parse elseif branch statements
                skip_newlines();
                last_node = elseif_node;

                while (!check(TokenType.ELSE) && !check(TokenType.ELSEIF) &&
                       !check(TokenType.ENDIF) && !is_at_end()) {
                    parse_statement();
                    skip_newlines();
                }

                // Mark the yes branch edge
                foreach (var edge in diagram.edges) {
                    if (edge.from == elseif_node && edge.label == null) {
                        edge.label = elseif_yes;
                        edge.is_yes_branch = true;
                        break;
                    }
                }

                if (last_node != null && last_node != elseif_node) {
                    branch_ends.add(last_node);
                }

                last_cond = elseif_node;
            }

            // Parse 'else' branch
            if (match(TokenType.ELSE)) {
                string no_label = "no";
                if (match(TokenType.LPAREN)) {
                    no_label = consume_until_rparen();
                }
                last_cond.condition_no = no_label;

                skip_newlines();
                last_node = last_cond;

                while (!check(TokenType.ENDIF) && !is_at_end()) {
                    parse_statement();
                    skip_newlines();
                }

                // Mark the no branch edge
                foreach (var edge in diagram.edges) {
                    if (edge.from == last_cond && !edge.is_yes_branch) {
                        edge.label = no_label;
                        edge.is_no_branch = true;
                        break;
                    }
                }

                if (last_node != null && last_node != last_cond) {
                    branch_ends.add(last_node);
                }
            }

            match(TokenType.ENDIF);
            int endif_line = previous().line;

            // Create merge point
            var merge = new ActivityNode(ActivityNodeType.MERGE, null, endif_line);
            diagram.add_node(merge);

            // Connect all branch ends to merge
            foreach (var branch_end in branch_ends) {
                if (branch_end.node_type != ActivityNodeType.STOP &&
                    branch_end.node_type != ActivityNodeType.END) {
                    diagram.connect(branch_end, merge);
                }
            }

            // If no else branch, connect last condition's no to merge
            if (!check(TokenType.ELSE)) {
                bool has_else_connection = false;
                foreach (var edge in diagram.edges) {
                    if (edge.from == last_cond && edge.is_no_branch) {
                        has_else_connection = true;
                        break;
                    }
                }
                if (!has_else_connection) {
                    var no_edge = new ActivityEdge(last_cond, merge, last_cond.condition_no);
                    no_edge.is_no_branch = true;
                    diagram.add_edge(no_edge);
                }
            }

            last_node = merge;
        }

        private void parse_fork(int source_line) throws Error {
            // Check for optional color: fork (#color) or fork (color)
            string? fork_color = null;
            if (match(TokenType.LPAREN)) {
                var color_sb = new StringBuilder();
                bool had_hash = false;
                if (check(TokenType.HASH)) {
                    had_hash = true;
                    advance();  // consume #
                }
                while (!check(TokenType.RPAREN) && !is_at_end()) {
                    color_sb.append(advance().lexeme);
                }
                string color_str = color_sb.str.strip();
                // Keep # only for hex colors (e.g., #FF0000), otherwise use name directly
                if (had_hash && color_str.length == 6 && is_hex_color(color_str)) {
                    fork_color = "#" + color_str;
                } else {
                    fork_color = color_str;
                }
                match(TokenType.RPAREN);
            }

            var fork_node = new ActivityNode(ActivityNodeType.FORK, null, source_line);
            fork_node.color = fork_color;
            add_node_with_connection(fork_node);

            var branch_ends = new Gee.ArrayList<ActivityNode>();
            skip_newlines();

            // First branch
            last_node = fork_node;
            while (!check_fork_again() && !check_end_fork() && !is_at_end()) {
                parse_statement();
                skip_newlines();
            }
            if (last_node != null && last_node != fork_node) {
                branch_ends.add(last_node);
            }

            // Additional branches
            while (match_fork_again()) {
                skip_newlines();
                last_node = fork_node;

                while (!check_fork_again() && !check_end_fork() && !is_at_end()) {
                    parse_statement();
                    skip_newlines();
                }
                if (last_node != null && last_node != fork_node) {
                    branch_ends.add(last_node);
                }
            }

            // Consume end fork
            match_end_fork();
            int end_fork_line = previous().line;

            // Join node (same color as fork)
            var join_node = new ActivityNode(ActivityNodeType.JOIN, null, end_fork_line);
            join_node.color = fork_color;
            diagram.add_node(join_node);

            foreach (var branch_end in branch_ends) {
                if (branch_end.node_type != ActivityNodeType.STOP &&
                    branch_end.node_type != ActivityNodeType.END) {
                    diagram.connect(branch_end, join_node);
                }
            }

            last_node = join_node;
        }

        private void parse_split(int source_line) throws Error {
            // Check for optional color: split (color)
            string? split_color = null;
            if (match(TokenType.LPAREN)) {
                var color_sb = new StringBuilder();
                if (check(TokenType.HASH)) {
                    advance();  // consume #
                }
                while (!check(TokenType.RPAREN) && !is_at_end()) {
                    color_sb.append(advance().lexeme);
                }
                string color_str = color_sb.str.strip();
                if (color_str.length == 6 && is_hex_color(color_str)) {
                    split_color = "#" + color_str;
                } else {
                    split_color = color_str;
                }
                match(TokenType.RPAREN);
            }

            // Split is like fork but branches don't synchronize
            var split_node = new ActivityNode(ActivityNodeType.FORK, null, source_line);
            split_node.color = split_color;
            add_node_with_connection(split_node);

            var branch_ends = new Gee.ArrayList<ActivityNode>();
            skip_newlines();

            // First branch
            last_node = split_node;
            while (!check_split_again() && !check_end_split() && !is_at_end()) {
                parse_statement();
                skip_newlines();
            }
            if (last_node != null && last_node != split_node) {
                branch_ends.add(last_node);
            }

            // Additional branches
            while (match_split_again()) {
                skip_newlines();
                last_node = split_node;

                while (!check_split_again() && !check_end_split() && !is_at_end()) {
                    parse_statement();
                    skip_newlines();
                }
                if (last_node != null && last_node != split_node) {
                    branch_ends.add(last_node);
                }
            }

            // Consume end split
            match_end_split();
            int end_split_line = previous().line;

            // Merge node (not join - paths don't synchronize)
            var merge_node = new ActivityNode(ActivityNodeType.MERGE, null, end_split_line);
            diagram.add_node(merge_node);

            foreach (var branch_end in branch_ends) {
                if (branch_end.node_type != ActivityNodeType.STOP &&
                    branch_end.node_type != ActivityNodeType.END) {
                    diagram.connect(branch_end, merge_node);
                }
            }

            last_node = merge_node;
        }

        private bool check_split_again() {
            if (check(TokenType.SPLIT) && check_next(TokenType.IDENTIFIER)) {
                if (current + 1 < tokens.size && tokens.get(current + 1).lexeme.down() == "again") {
                    return true;
                }
            }
            return false;
        }

        private bool match_split_again() {
            if (check_split_again()) {
                advance();  // SPLIT
                advance();  // again
                return true;
            }
            return false;
        }

        private bool check_end_split() {
            if (check(TokenType.END)) {
                if (current + 1 < tokens.size) {
                    var next = tokens.get(current + 1);
                    if (next.token_type == TokenType.SPLIT) {
                        return true;
                    }
                }
            }
            return false;
        }

        private bool match_end_split() {
            if (check_end_split()) {
                advance();  // END
                advance();  // SPLIT
                return true;
            }
            return false;
        }

        private void parse_while(int source_line) throws Error {
            // Check for optional color: while (#color) (condition) or while (color) (condition)
            string? while_color = null;
            string condition = "";

            if (match(TokenType.LPAREN)) {
                // Check if this looks like a color (starts with # or is a color name followed by another paren)
                if (check(TokenType.HASH)) {
                    advance();  // consume #
                    var color_sb = new StringBuilder();
                    while (!check(TokenType.RPAREN) && !is_at_end()) {
                        color_sb.append(advance().lexeme);
                    }
                    string color_str = color_sb.str.strip();
                    if (color_str.length == 6 && is_hex_color(color_str)) {
                        while_color = "#" + color_str;
                    } else {
                        while_color = color_str;
                    }
                    match(TokenType.RPAREN);
                    // Now parse the actual condition
                    if (match(TokenType.LPAREN)) {
                        condition = consume_until_rparen();
                    }
                } else {
                    // Could be color without # or could be the condition
                    // Peek ahead: if there's another ( after ), it's a color
                    string first_content = consume_until_rparen();
                    skip_whitespace_only();
                    if (check(TokenType.LPAREN)) {
                        // First was color, now parse condition
                        while_color = first_content;
                        match(TokenType.LPAREN);
                        condition = consume_until_rparen();
                    } else {
                        // First was the condition
                        condition = first_content;
                    }
                }
            }

            var cond_node = new ActivityNode(ActivityNodeType.CONDITION, condition, source_line);
            cond_node.color = while_color;
            add_node_with_connection(cond_node);

            // Parse loop body
            skip_newlines();
            last_node = cond_node;

            while (!check(TokenType.ENDWHILE) && !is_at_end()) {
                parse_statement();
                skip_newlines();
            }

            // Connect back to condition
            if (last_node != null && last_node != cond_node) {
                diagram.connect(last_node, cond_node);
            }

            match(TokenType.ENDWHILE);
            int endwhile_line = previous().line;

            // Parse exit condition label
            string exit_label = "";
            if (match(TokenType.LPAREN)) {
                exit_label = consume_until_rparen();
            }

            // Create exit merge point
            var exit_node = new ActivityNode(ActivityNodeType.MERGE, null, endwhile_line);
            diagram.add_node(exit_node);

            var exit_edge = new ActivityEdge(cond_node, exit_node, exit_label);
            diagram.add_edge(exit_edge);

            // Connect any pending breaks to exit
            foreach (var break_node in pending_breaks) {
                diagram.connect(break_node, exit_node);
            }
            pending_breaks.clear();

            last_node = exit_node;
        }

        private void parse_repeat(int source_line) throws Error {
            var repeat_start = new ActivityNode(ActivityNodeType.MERGE, null, source_line);
            add_node_with_connection(repeat_start);

            skip_newlines();

            // Parse loop body until "repeat while" or "backward"
            string? backward_label = null;
            while (!check_repeat_while() && !check_backward() && !is_at_end()) {
                parse_statement();
                skip_newlines();
            }

            // Check for backward label
            if (match_backward()) {
                // Parse backward action text
                if (match(TokenType.COLON)) {
                    var sb = new StringBuilder();
                    while (!check(TokenType.SEMICOLON) && !check(TokenType.NEWLINE) && !is_at_end()) {
                        Token t = advance();
                        if (sb.len > 0) sb.append(" ");
                        sb.append(t.lexeme);
                    }
                    match(TokenType.SEMICOLON);
                    backward_label = sb.str.strip();
                }
                skip_newlines();
            }

            // Consume "repeat while"
            match_repeat_while();

            string condition = "";
            if (match(TokenType.LPAREN)) {
                condition = consume_until_rparen();
            }

            // Optional "is (yes)" label
            string yes_label = "yes";
            if (check(TokenType.IDENTIFIER) && peek().lexeme.down() == "is") {
                advance();  // consume "is"
                if (match(TokenType.LPAREN)) {
                    yes_label = consume_until_rparen();
                }
            }

            // Optional "not (no)" label
            string no_label = "no";
            if (check(TokenType.IDENTIFIER) && peek().lexeme.down() == "not") {
                advance();  // consume "not"
                if (match(TokenType.LPAREN)) {
                    no_label = consume_until_rparen();
                }
            }

            int repeat_while_line = previous().line;  // "repeat while" keyword line
            var cond_node = new ActivityNode(ActivityNodeType.CONDITION, condition, repeat_while_line);
            cond_node.condition_yes = yes_label;
            cond_node.condition_no = no_label;
            diagram.add_node(cond_node);
            if (last_node != null) {
                diagram.connect(last_node, cond_node);
            }

            // Loop back edge (when condition is true)
            string loop_label = backward_label != null ? backward_label : yes_label;
            var loop_edge = new ActivityEdge(cond_node, repeat_start, loop_label);
            loop_edge.is_yes_branch = true;
            diagram.add_edge(loop_edge);

            // Exit node (when condition is false)
            var exit_node = new ActivityNode(ActivityNodeType.MERGE, null, repeat_while_line);
            diagram.add_node(exit_node);
            var exit_edge = new ActivityEdge(cond_node, exit_node, no_label);
            exit_edge.is_no_branch = true;
            diagram.add_edge(exit_edge);

            // Connect any pending breaks to exit
            foreach (var break_node in pending_breaks) {
                diagram.connect(break_node, exit_node);
            }
            pending_breaks.clear();

            last_node = exit_node;
        }

        private void parse_switch(int source_line) throws Error {
            // Parse switch condition
            string condition = "";
            if (match(TokenType.LPAREN)) {
                condition = consume_until_rparen();
            }

            var switch_node = new ActivityNode(ActivityNodeType.CONDITION, condition, source_line);
            add_node_with_connection(switch_node);

            var case_ends = new Gee.ArrayList<ActivityNode>();
            skip_newlines();

            // Parse case branches
            while (match(TokenType.CASE)) {
                string case_label = "";
                if (match(TokenType.LPAREN)) {
                    case_label = consume_until_rparen();
                }

                skip_newlines();

                // Connect switch to this case branch
                last_node = switch_node;

                // Track if this is the first statement in the case
                bool first_in_case = true;

                // Parse case body
                while (!check(TokenType.CASE) && !check(TokenType.ENDSWITCH) && !is_at_end()) {
                    int before_count = diagram.nodes.size;
                    parse_statement();

                    // Label the first edge from switch to this case
                    if (first_in_case && diagram.nodes.size > before_count) {
                        foreach (var edge in diagram.edges) {
                            if (edge.from == switch_node && edge.to == last_node) {
                                edge.label = case_label;
                                break;
                            }
                        }
                        first_in_case = false;
                    }

                    skip_newlines();
                }

                // Save the end of this case branch
                if (last_node != null && last_node != switch_node) {
                    case_ends.add(last_node);
                }
            }

            match(TokenType.ENDSWITCH);
            int endswitch_line = previous().line;

            // Create merge point for all case branches
            var merge = new ActivityNode(ActivityNodeType.MERGE, null, endswitch_line);
            diagram.add_node(merge);

            foreach (var case_end in case_ends) {
                if (case_end.node_type != ActivityNodeType.STOP &&
                    case_end.node_type != ActivityNodeType.END) {
                    diagram.connect(case_end, merge);
                }
            }

            last_node = merge;
        }

        private void parse_swimlane() throws Error {
            // Parse swimlane: |Name|, |#color|Name|, or |[#color]alias| Title
            string? color = null;
            string? alias = null;
            var sb = new StringBuilder();

            // Check for alias syntax: |[#color]alias| or |[alias]|
            if (check(TokenType.LBRACKET)) {
                advance();  // consume [

                // Check for color inside brackets
                if (check(TokenType.HASH)) {
                    advance();  // consume #
                    var color_sb = new StringBuilder();
                    while (!check(TokenType.RBRACKET) && !check(TokenType.PIPE) && !is_at_end()) {
                        color_sb.append(advance().lexeme);
                    }
                    color = color_sb.str.strip();
                }

                match(TokenType.RBRACKET);  // consume ]

                // Get alias (text after ] but before |)
                var alias_sb = new StringBuilder();
                while (!check(TokenType.PIPE) && !check(TokenType.NEWLINE) && !is_at_end()) {
                    Token t = advance();
                    if (alias_sb.len > 0) {
                        alias_sb.append(" ");
                    }
                    alias_sb.append(t.lexeme);
                }
                alias = alias_sb.str.strip();

                match(TokenType.PIPE);  // consume middle |

                // Get title (display name)
                while (!check(TokenType.PIPE) && !check(TokenType.NEWLINE) && !is_at_end()) {
                    Token t = advance();
                    if (sb.len > 0) {
                        sb.append(" ");
                    }
                    sb.append(t.lexeme);
                }
            } else if (check(TokenType.HASH)) {
                // Old syntax: |#color|Name|
                advance();  // consume #
                var color_sb = new StringBuilder();
                while (!check(TokenType.PIPE) && !check(TokenType.NEWLINE) && !is_at_end()) {
                    color_sb.append(advance().lexeme);
                }
                color = color_sb.str.strip();

                match(TokenType.PIPE);  // consume middle |

                // Collect name until closing pipe
                while (!check(TokenType.PIPE) && !check(TokenType.NEWLINE) && !is_at_end()) {
                    Token t = advance();
                    if (sb.len > 0) {
                        sb.append(" ");
                    }
                    sb.append(t.lexeme);
                }
            } else {
                // Simple syntax: |Name|
                while (!check(TokenType.PIPE) && !check(TokenType.NEWLINE) && !is_at_end()) {
                    Token t = advance();
                    if (sb.len > 0) {
                        sb.append(" ");
                    }
                    sb.append(t.lexeme);
                }
            }

            match(TokenType.PIPE);  // consume closing |

            string name = sb.str.strip();
            if (name.length > 0 || (alias != null && alias.length > 0)) {
                // Use alias as lookup key if provided, otherwise use name
                string lookup_key = (alias != null && alias.length > 0) ? alias : name;
                string display_name = name.length > 0 ? name : (alias != null ? alias : "");

                current_partition = lookup_key;

                // Add partition to diagram if not already present
                bool found = false;
                foreach (var p in diagram.partitions) {
                    if (p.name == lookup_key || (p.alias != null && p.alias == lookup_key)) {
                        found = true;
                        // Update color if provided
                        if (color != null) {
                            p.color = color;
                        }
                        break;
                    }
                }
                if (!found) {
                    var partition = new ActivityPartition(display_name, color, alias);
                    diagram.partitions.add(partition);
                }
            }
        }

        private void parse_partition() throws Error {
            // Parse: partition #color "Name" { ... } or partition "Name" { ... }
            string name = "";
            string? partition_color = null;

            // Check for optional color: partition #color or partition (color)
            if (check(TokenType.HASH)) {
                advance();  // consume #
                if (check(TokenType.IDENTIFIER)) {
                    string color_str = advance().lexeme;
                    if (color_str.length == 6 && is_hex_color(color_str)) {
                        partition_color = "#" + color_str;
                    } else {
                        partition_color = color_str;
                    }
                }
            } else if (match(TokenType.LPAREN)) {
                var color_sb = new StringBuilder();
                if (check(TokenType.HASH)) {
                    advance();
                }
                while (!check(TokenType.RPAREN) && !is_at_end()) {
                    color_sb.append(advance().lexeme);
                }
                string color_str = color_sb.str.strip();
                if (color_str.length == 6 && is_hex_color(color_str)) {
                    partition_color = "#" + color_str;
                } else {
                    partition_color = color_str;
                }
                match(TokenType.RPAREN);
            }

            // Get partition name (string or identifier)
            if (match(TokenType.STRING)) {
                name = previous().lexeme;
            } else if (check(TokenType.IDENTIFIER)) {
                name = advance().lexeme;
            }

            // Save previous partition for nesting
            string? prev_partition = current_partition;
            current_partition = name;

            // Add partition to diagram
            bool found = false;
            foreach (var p in diagram.partitions) {
                if (p.name == name) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                diagram.partitions.add(new ActivityPartition(name, partition_color));
            }

            skip_newlines();

            // Parse partition body in braces
            if (match(TokenType.LBRACE)) {
                skip_newlines();

                while (!check(TokenType.RBRACE) && !is_at_end()) {
                    parse_statement();
                    skip_newlines();
                }

                match(TokenType.RBRACE);
            }

            // Restore previous partition
            current_partition = prev_partition;
        }

        private void parse_group() throws Error {
            // Parse: group #color Name or group Name #color ... end group
            string? group_color = null;
            var name_sb = new StringBuilder();

            // Check for color at start
            if (check(TokenType.HASH)) {
                advance();  // consume #
                if (check(TokenType.IDENTIFIER)) {
                    string color_str = advance().lexeme;
                    if (color_str.length == 6 && is_hex_color(color_str)) {
                        group_color = "#" + color_str;
                    } else {
                        group_color = color_str;
                    }
                }
            }

            // Collect group name until newline or #
            while (!check(TokenType.NEWLINE) && !check(TokenType.HASH) && !is_at_end()) {
                Token t = advance();
                if (name_sb.len > 0) {
                    name_sb.append(" ");
                }
                name_sb.append(t.lexeme);
            }

            // Check for color at end
            if (check(TokenType.HASH)) {
                advance();  // consume #
                if (check(TokenType.IDENTIFIER)) {
                    string color_str = advance().lexeme;
                    if (color_str.length == 6 && is_hex_color(color_str)) {
                        group_color = "#" + color_str;
                    } else {
                        group_color = color_str;
                    }
                }
            }

            string name = name_sb.str.strip();

            // Save previous partition for nesting
            string? prev_partition = current_partition;
            current_partition = name;

            // Add as partition with color
            if (name.length > 0) {
                bool found = false;
                foreach (var p in diagram.partitions) {
                    if (p.name == name) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    diagram.partitions.add(new ActivityPartition(name, group_color));
                }
            }

            skip_newlines();

            // Parse group body until "end group"
            while (!check_end_group() && !is_at_end()) {
                parse_statement();
                skip_newlines();
            }

            // Consume "end group"
            match_end_group();

            // Restore previous partition
            current_partition = prev_partition;
        }

        private bool check_end_group() {
            if (check(TokenType.END)) {
                if (current + 1 < tokens.size) {
                    var next = tokens.get(current + 1);
                    if (next.token_type == TokenType.GROUP) {
                        return true;
                    }
                }
            }
            return false;
        }

        private bool match_end_group() {
            if (check_end_group()) {
                advance();  // END
                advance();  // GROUP
                return true;
            }
            return false;
        }

        private void parse_title() throws Error {
            var sb = new StringBuilder();

            // Collect title until newline
            while (!check(TokenType.NEWLINE) && !is_at_end()) {
                Token t = advance();
                if (sb.len > 0) {
                    sb.append(" ");
                }
                sb.append(t.lexeme);
            }

            diagram.title = sb.str.strip();
        }

        private void parse_header() throws Error {
            var sb = new StringBuilder();

            // Collect header until newline
            while (!check(TokenType.NEWLINE) && !is_at_end()) {
                Token t = advance();
                if (sb.len > 0) {
                    sb.append(" ");
                }
                sb.append(t.lexeme);
            }

            diagram.header = sb.str.strip();
        }

        private void parse_footer() throws Error {
            var sb = new StringBuilder();

            // Collect footer until newline
            while (!check(TokenType.NEWLINE) && !is_at_end()) {
                Token t = advance();
                if (sb.len > 0) {
                    sb.append(" ");
                }
                sb.append(t.lexeme);
            }

            diagram.footer = sb.str.strip();
        }

        private void parse_caption() throws Error {
            var sb = new StringBuilder();

            // Collect caption until newline
            while (!check(TokenType.NEWLINE) && !is_at_end()) {
                Token t = advance();
                if (sb.len > 0) {
                    sb.append(" ");
                }
                sb.append(t.lexeme);
            }

            diagram.caption = sb.str.strip();
        }

        private void parse_legend() throws Error {
            // Parse: legend left / legend right / legend center
            // followed by text until "endlegend" or "end legend"
            LegendPosition position = LegendPosition.RIGHT;  // default

            if (match(TokenType.LEFT)) {
                position = LegendPosition.LEFT;
            } else if (match(TokenType.RIGHT)) {
                position = LegendPosition.RIGHT;
            } else if (match(TokenType.CENTER)) {
                position = LegendPosition.CENTER;
            }

            skip_newlines();

            var sb = new StringBuilder();

            // Collect text until "endlegend" or "end legend"
            // Handle Creole markers specially to avoid unwanted spaces
            while (!check_end_legend() && !is_at_end()) {
                if (check(TokenType.NEWLINE)) {
                    if (sb.len > 0) {
                        sb.append("\n");
                    }
                    advance();
                } else {
                    Token t = advance();
                    string lexeme = t.lexeme;

                    bool should_add_space = sb.len > 0 && !sb.str.has_suffix("\n");

                    if (should_add_space) {
                        should_add_space = should_add_space_before(sb.str, lexeme);
                    }

                    if (should_add_space) {
                        sb.append(" ");
                    }
                    sb.append(lexeme);
                }
            }

            // Consume "endlegend" or "end legend"
            match_end_legend();

            diagram.legend = new ActivityLegend(sb.str.strip(), position);
        }

        private bool check_end_legend() {
            // Check for "endlegend" as single identifier
            if (check(TokenType.IDENTIFIER) && peek().lexeme.down() == "endlegend") {
                return true;
            }
            // Check for "end legend" as two tokens
            if (check(TokenType.END)) {
                if (current + 1 < tokens.size) {
                    var next = tokens.get(current + 1);
                    if (next.token_type == TokenType.LEGEND) {
                        return true;
                    }
                }
            }
            return false;
        }

        private bool match_end_legend() {
            if (check(TokenType.IDENTIFIER) && peek().lexeme.down() == "endlegend") {
                advance();
                return true;
            }
            if (check(TokenType.END)) {
                if (current + 1 < tokens.size) {
                    var next = tokens.get(current + 1);
                    if (next.token_type == TokenType.LEGEND) {
                        advance();  // END
                        advance();  // LEGEND
                        return true;
                    }
                }
            }
            return false;
        }

        private void parse_note(bool is_floating = false) throws Error {
            // Parse: note left: text  OR  note right: text
            // OR: note left #color: text  OR  note right #color: text
            // OR: note left / note right followed by text and "end note"
            // OR: floating note left: text (not attached to any node)
            // OR: note on link: text (attached to next edge)

            // Check for "note on link" pattern
            if (check(TokenType.IDENTIFIER) && peek().lexeme.down() == "on") {
                advance();  // consume "on"
                if (check(TokenType.IDENTIFIER) && peek().lexeme.down() == "link") {
                    advance();  // consume "link"
                    // Parse note text after colon
                    if (match(TokenType.COLON)) {
                        var sb = new StringBuilder();
                        while (!check(TokenType.NEWLINE) && !is_at_end()) {
                            if (sb.len > 0) sb.append(" ");
                            sb.append(advance().lexeme);
                        }
                        pending_edge_note = sb.str.strip();
                    }
                    return;
                }
            }

            NotePosition position = NotePosition.RIGHT;  // default
            string? note_color = null;

            if (match(TokenType.LEFT)) {
                position = NotePosition.LEFT;
            } else if (match(TokenType.RIGHT)) {
                position = NotePosition.RIGHT;
            } else if (match(TokenType.TOP)) {
                position = NotePosition.TOP;
            } else if (match(TokenType.BOTTOM)) {
                position = NotePosition.BOTTOM;
            }

            // Check for optional color: #color
            if (check(TokenType.HASH)) {
                advance();  // consume #
                var color_sb = new StringBuilder();
                while (!check(TokenType.COLON) && !check(TokenType.NEWLINE) && !is_at_end()) {
                    color_sb.append(advance().lexeme);
                }
                note_color = color_sb.str.strip();
            }

            var sb = new StringBuilder();

            // Check for inline note (with colon)
            if (match(TokenType.COLON)) {
                // Inline note - collect until newline
                // Handle Creole markers specially
                while (!check(TokenType.NEWLINE) && !is_at_end()) {
                    Token t = advance();
                    string lexeme = t.lexeme;

                    bool should_add_space = sb.len > 0;
                    if (should_add_space) {
                        should_add_space = should_add_space_before(sb.str, lexeme);
                    }

                    if (should_add_space) {
                        sb.append(" ");
                    }
                    sb.append(lexeme);
                }
            } else {
                // Multiline note - collect until "end note"
                skip_newlines();

                // Handle Creole markers specially
                while (!check_end_note() && !is_at_end()) {
                    if (check(TokenType.NEWLINE)) {
                        if (sb.len > 0) {
                            sb.append("\n");
                        }
                        advance();
                    } else {
                        Token t = advance();
                        string lexeme = t.lexeme;

                        bool should_add_space = sb.len > 0 && !sb.str.has_suffix("\n");
                        if (should_add_space) {
                            should_add_space = should_add_space_before(sb.str, lexeme);
                        }

                        if (should_add_space) {
                            sb.append(" ");
                        }
                        sb.append(lexeme);
                    }
                }

                // Consume "end note"
                match_end_note();
            }

            // Attach note
            ActivityNode? attached_to = is_floating ? null : last_node;
            var note = new ActivityNote(sb.str.strip(), position, attached_to, note_color);
            diagram.notes.add(note);
        }

        private bool check_end_note() {
            if (check(TokenType.END)) {
                // Check if next token is NOTE
                if (current + 1 < tokens.size) {
                    var next = tokens.get(current + 1);
                    if (next.token_type == TokenType.NOTE) {
                        return true;
                    }
                }
            }
            return false;
        }

        private bool match_end_note() {
            if (check_end_note()) {
                advance();  // END
                advance();  // NOTE
                return true;
            }
            return false;
        }

        private void parse_connector(int source_line) throws Error {
            // Parse: (A) - connector/goto label
            // First occurrence defines the connector, subsequent ones jump to it

            var name_sb = new StringBuilder();

            // Collect name until closing paren
            while (!check(TokenType.RPAREN) && !check(TokenType.NEWLINE) && !is_at_end()) {
                Token t = advance();
                name_sb.append(t.lexeme);
            }

            match(TokenType.RPAREN);

            string name = name_sb.str.strip();
            if (name.length == 0) {
                return;
            }

            // Check if this connector already exists
            if (connectors.has_key(name)) {
                // This is a goto - connect last_node to the existing connector
                var target = connectors.get(name);
                if (last_node != null) {
                    diagram.connect(last_node, target, pending_edge_label);
                    pending_edge_label = null;
                }
                // After a goto, we don't have a last_node (flow continues elsewhere)
                last_node = null;
            } else {
                // First occurrence - create the connector node
                var node = new ActivityNode(ActivityNodeType.CONNECTOR, name, source_line);
                add_node_with_connection(node);
                connectors.set(name, node);
            }
        }

        private string consume_until_rparen() {
            var sb = new StringBuilder();
            int depth = 1;

            while (depth > 0 && !is_at_end()) {
                if (check(TokenType.LPAREN)) {
                    depth++;
                } else if (check(TokenType.RPAREN)) {
                    depth--;
                    if (depth == 0) {
                        advance();
                        break;
                    }
                }
                Token t = advance();

                // Skip spaces around UTF-8 bytes (lexer tokenizes them separately)
                bool is_utf8_byte = false;
                if (t.lexeme.length == 1) {
                    uint8 b = (uint8)t.lexeme[0];
                    is_utf8_byte = b >= 0x80;
                }
                bool prev_ends_with_utf8 = false;
                if (sb.len > 0) {
                    uint8 last_b = (uint8)sb.str[sb.len - 1];
                    prev_ends_with_utf8 = last_b >= 0x80;
                }

                if (sb.len > 0 && !is_utf8_byte && !prev_ends_with_utf8) {
                    sb.append(" ");
                }
                sb.append(t.lexeme);
            }

            return sb.str.strip();
        }

        private void add_node_with_connection(ActivityNode node) {
            // Assign current partition to node
            node.partition = current_partition;

            diagram.add_node(node);

            if (last_node != null) {
                var edge = new ActivityEdge(last_node, node, pending_edge_label);
                edge.color = pending_edge_color;
                edge.style = pending_edge_style;
                edge.direction = pending_edge_direction;
                edge.note = pending_edge_note;
                diagram.add_edge(edge);
                pending_edge_label = null;
                pending_edge_color = null;
                pending_edge_style = null;
                pending_edge_direction = EdgeDirection.DEFAULT;
                pending_edge_note = null;
            }

            // Connect pending nodes
            foreach (var pending in pending_connections) {
                diagram.connect(pending, node);
            }
            pending_connections.clear();

            last_node = node;
        }

        // Determine if we should add a space before a token during text collection
        // for Creole formatting support. Returns true if space should be added.
        private bool should_add_space_before(string prev_text, string next_lexeme) {
            // Skip spaces around UTF-8 bytes (lexer tokenizes multi-byte chars separately)
            // UTF-8 high bytes are >= 0x80
            if (next_lexeme.length == 1) {
                uint8 b = (uint8)next_lexeme[0];
                if (b >= 0x80) return false;  // Don't add space before UTF-8 byte
            }
            if (prev_text.length > 0) {
                uint8 last_b = (uint8)prev_text[prev_text.length - 1];
                if (last_b >= 0x80) return false;  // Don't add space after UTF-8 byte
            }

            // Creole marker characters
            bool next_is_marker = next_lexeme == "*" || next_lexeme == "/" ||
                                  next_lexeme == "_" || next_lexeme == "~";
            // Note: "-" is tricky because it's also used in regular text

            // Check what the previous text ends with
            bool prev_ends_single_star = prev_text.has_suffix("*") && !prev_text.has_suffix("**");
            bool prev_ends_single_slash = prev_text.has_suffix("/") && !prev_text.has_suffix("//");
            bool prev_ends_single_underscore = prev_text.has_suffix("_") && !prev_text.has_suffix("__");
            bool prev_ends_single_tilde = prev_text.has_suffix("~") && !prev_text.has_suffix("~~");

            bool prev_ends_double_star = prev_text.has_suffix("**");
            bool prev_ends_double_slash = prev_text.has_suffix("//");
            bool prev_ends_double_underscore = prev_text.has_suffix("__");
            bool prev_ends_double_tilde = prev_text.has_suffix("~~");

            // Count markers to determine if we're inside formatting
            int star_count = count_occurrences(prev_text, "**");
            int slash_count = count_occurrences(prev_text, "//");
            int underscore_count = count_occurrences(prev_text, "__");
            int tilde_count = count_occurrences(prev_text, "~~");

            // Rule 1: Don't add space between two consecutive markers of same type
            // e.g., "*" followed by "*" should produce "**"
            if (prev_ends_single_star && next_lexeme == "*") return false;
            if (prev_ends_single_slash && next_lexeme == "/") return false;
            if (prev_ends_single_underscore && next_lexeme == "_") return false;
            if (prev_ends_single_tilde && next_lexeme == "~") return false;

            // Rule 2: Don't add space after OPENING double markers (odd count = inside)
            // e.g., "**" followed by "Bold" should produce "**Bold"
            // But "**Bold**" followed by "and" should produce "**Bold** and"
            if (prev_ends_double_star && !next_is_marker && star_count % 2 == 1) return false;
            if (prev_ends_double_slash && !next_is_marker && slash_count % 2 == 1) return false;
            if (prev_ends_double_underscore && !next_is_marker && underscore_count % 2 == 1) return false;
            if (prev_ends_double_tilde && !next_is_marker && tilde_count % 2 == 1) return false;

            // Rule 3: Don't add space before closing markers (first marker of pair)
            // e.g., "Bold" followed by "*" should produce "Bold*"
            // If the text contains an odd number of double markers, we're inside
            if (next_is_marker) {
                // If we're inside bold (odd count of **) and next is *, don't add space
                if (next_lexeme == "*" && star_count % 2 == 1) return false;
                if (next_lexeme == "/" && slash_count % 2 == 1) return false;
                if (next_lexeme == "_" && underscore_count % 2 == 1) return false;
                if (next_lexeme == "~" && tilde_count % 2 == 1) return false;
            }

            // Default: add space
            return true;
        }

        // Count non-overlapping occurrences of a substring
        private int count_occurrences(string text, string sub) {
            int count = 0;
            int pos = 0;
            while ((pos = text.index_of(sub, pos)) >= 0) {
                count++;
                pos += sub.length;
            }
            return count;
        }

        private bool check_next(TokenType type) {
            if (current + 1 >= tokens.size) return false;
            return tokens.get(current + 1).token_type == type;
        }

        private bool check_next_lexeme(string lexeme) {
            if (current + 1 >= tokens.size) return false;
            return tokens.get(current + 1).lexeme == lexeme;
        }

        private bool is_hex_color(string str) {
            if (str.length != 6) return false;
            foreach (char c in str.to_utf8()) {
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) {
                    return false;
                }
            }
            return true;
        }

        private void skip_whitespace_only() {
            // Skip whitespace tokens but not newlines
            while (!is_at_end() && check(TokenType.NEWLINE)) {
                // Don't skip newlines here
                break;
            }
        }

        private bool check_end_fork() {
            // Check for "end fork" or "end merge" as two tokens
            if (check(TokenType.END)) {
                if (check_next(TokenType.FORK) || check_next(TokenType.MERGE)) {
                    return true;
                }
            }
            return false;
        }

        private bool match_end_fork() {
            if (check(TokenType.END)) {
                if (check_next(TokenType.FORK) || check_next(TokenType.MERGE)) {
                    advance();
                    advance();
                    return true;
                }
            }
            return false;
        }

        private bool check_fork_again() {
            // Check for "fork again" as two tokens without consuming
            if (check(TokenType.FORK) && check_next(TokenType.IDENTIFIER)) {
                if (current + 1 < tokens.size && tokens.get(current + 1).lexeme.down() == "again") {
                    return true;
                }
            }
            return false;
        }

        private bool match_fork_again() {
            // Check for "fork again" as two tokens
            if (check_fork_again()) {
                advance();
                advance();
                return true;
            }
            return false;
        }

        private bool check_repeat_while() {
            if (check(TokenType.REPEAT) && check_next(TokenType.WHILE)) {
                return true;
            }
            return false;
        }

        private bool match_repeat_while() {
            if (check(TokenType.REPEAT) && check_next(TokenType.WHILE)) {
                advance();
                advance();
                return true;
            }
            return false;
        }

        private bool check_backward() {
            return check(TokenType.BACKWARD);
        }

        private bool match_backward() {
            if (check(TokenType.BACKWARD)) {
                advance();
                return true;
            }
            return false;
        }

        private void synchronize() {
            while (!is_at_end()) {
                if (previous().token_type == TokenType.NEWLINE) {
                    return;
                }

                switch (peek().token_type) {
                    case TokenType.START:
                    case TokenType.STOP:
                    case TokenType.IF:
                    case TokenType.FORK:
                    case TokenType.WHILE:
                    case TokenType.REPEAT:
                    case TokenType.ENDUML:
                        return;
                    default:
                        advance();
                        break;
                }
            }
        }

        private void skip_newlines() {
            while (match(TokenType.NEWLINE) || match(TokenType.COMMENT)) {
                // keep skipping
            }
        }

        private bool match(TokenType type) {
            if (check(type)) {
                advance();
                return true;
            }
            return false;
        }

        private bool check(TokenType type) {
            if (is_at_end()) return false;
            return peek().token_type == type;
        }

        private Token advance() {
            if (!is_at_end()) {
                current++;
            }
            return previous();
        }

        private bool is_at_end() {
            return peek().token_type == TokenType.EOF;
        }

        private Token peek() {
            return tokens.get(current);
        }

        private Token previous() {
            return tokens.get(current - 1);
        }
    }
}
