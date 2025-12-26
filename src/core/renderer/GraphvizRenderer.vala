namespace GPlantUML {
    // Element region for click-to-source navigation
    public class ElementRegion : Object {
        public string name { get; set; }
        public int source_line { get; set; }
        public double x { get; set; }
        public double y { get; set; }
        public double width { get; set; }
        public double height { get; set; }

        public ElementRegion(string name, int line, double x, double y, double w, double h) {
            this.name = name;
            this.source_line = line;
            this.x = x;
            this.y = y;
            this.width = w;
            this.height = h;
        }
    }

    public class GraphvizRenderer : Object {
        private Gvc.Context context;
        private SkinParams? current_skin_params;

        // Stores element regions from last render for click navigation
        public Gee.ArrayList<ElementRegion> last_regions { get; private set; }

        // Layout engine to use (dot, neato, fdp, sfdp, circo, twopi)
        public string layout_engine { get; set; default = "dot"; }

        // Available layout engines
        public static string[] LAYOUT_ENGINES = { "dot", "neato", "fdp", "sfdp", "circo", "twopi" };

        public GraphvizRenderer() {
            context = new Gvc.Context();
            current_skin_params = null;
            last_regions = new Gee.ArrayList<ElementRegion>();
        }

        public string generate_dot(SequenceDiagram diagram) {
            var sb = new StringBuilder();

            sb.append("digraph sequence {\n");
            sb.append("  rankdir=TB;\n");
            sb.append("  node [shape=box, style=filled, fillcolor=\"#FEFECE\", fontname=\"Sans\"];\n");
            sb.append("  edge [fontsize=10, fontname=\"Sans\"];\n");
            sb.append("  splines=polyline;\n");
            sb.append("\n");

            // Create participant nodes in order
            sb.append("  // Participants\n");
            sb.append("  { rank=same;\n");
            foreach (var p in diagram.participants) {
                string shape = get_participant_shape(p.participant_type);
                string id = escape_id(p.get_id());
                string label = escape_label(p.name);
                sb.append("    %s [label=\"%s\", shape=%s];\n".printf(id, label, shape));
            }
            sb.append("  }\n\n");

            // Create invisible edges to maintain participant order
            if (diagram.participants.size > 1) {
                sb.append("  // Ordering\n");
                sb.append("  edge [style=invis];\n");
                for (int i = 0; i < diagram.participants.size - 1; i++) {
                    string id1 = escape_id(diagram.participants[i].get_id());
                    string id2 = escape_id(diagram.participants[i + 1].get_id());
                    sb.append("  %s -> %s;\n".printf(id1, id2));
                }
                sb.append("\n");
            }

            // Create message edges
            sb.append("  // Messages\n");
            sb.append("  edge [style=solid, constraint=false];\n");
            int msg_num = 0;
            foreach (var msg in diagram.messages) {
                string from_id = escape_id(msg.from.get_id());
                string to_id = escape_id(msg.to.get_id());
                string label = msg.label != null ? escape_label(msg.label) : "";
                string style = get_arrow_style(msg.style);
                string arrow = get_arrowhead(msg.style, msg.direction);

                // For sequence diagrams, we create intermediate nodes for message ordering
                string msg_node = "msg%d".printf(msg_num);
                sb.append("  %s [shape=point, width=0, height=0, label=\"\"];\n".printf(msg_node));

                if (msg.direction == ArrowDirection.LEFT) {
                    sb.append("  %s -> %s [label=\"%s\", style=%s, arrowhead=%s, dir=back];\n".printf(
                        to_id, from_id, label, style, arrow
                    ));
                } else {
                    sb.append("  %s -> %s [label=\"%s\", style=%s, arrowhead=%s];\n".printf(
                        from_id, to_id, label, style, arrow
                    ));
                }
                msg_num++;
            }

            // Create note nodes
            if (diagram.notes.size > 0) {
                sb.append("\n  // Notes\n");
                int note_num = 0;
                foreach (var note in diagram.notes) {
                    string note_id = "note%d".printf(note_num);
                    string note_text = escape_label(note.text);
                    sb.append("  %s [shape=note, style=filled, fillcolor=\"#FFFFCC\", label=\"%s\"];\n".printf(
                        note_id, note_text
                    ));

                    // Connect note to participant if specified
                    if (note.participant != null) {
                        string part_id = escape_id(note.participant.get_id());
                        sb.append("  %s -> %s [style=dotted, arrowhead=none, constraint=false];\n".printf(
                            note_id, part_id
                        ));
                    }
                    note_num++;
                }
            }

            // Render grouping frames as clusters
            if (diagram.frames.size > 0) {
                sb.append("\n  // Grouping Frames\n");
                foreach (var frame in diagram.frames) {
                    render_frame_cluster(sb, frame, diagram);
                }
            }

            sb.append("}\n");

            return sb.str;
        }

        private string get_participant_shape(ParticipantType ptype) {
            switch (ptype) {
                case ParticipantType.ACTOR:
                    return "ellipse";
                case ParticipantType.BOUNDARY:
                    return "component";
                case ParticipantType.CONTROL:
                    return "circle";
                case ParticipantType.ENTITY:
                    return "box3d";
                case ParticipantType.DATABASE:
                    return "cylinder";
                case ParticipantType.COLLECTIONS:
                    return "folder";
                case ParticipantType.QUEUE:
                    return "cds";
                default:
                    return "box";
            }
        }

        private string get_arrow_style(ArrowStyle style) {
            switch (style) {
                case ArrowStyle.DOTTED:
                case ArrowStyle.DOTTED_OPEN:
                    return "dashed";
                default:
                    return "solid";
            }
        }

        private string get_arrowhead(ArrowStyle style, ArrowDirection dir) {
            if (dir == ArrowDirection.BIDIRECTIONAL) {
                return "normal";
            }
            switch (style) {
                case ArrowStyle.SOLID_OPEN:
                case ArrowStyle.DOTTED_OPEN:
                    return "open";
                default:
                    return "normal";
            }
        }

        private void render_frame_cluster(StringBuilder sb, SequenceFrame frame, SequenceDiagram diagram) {
            string frame_id = frame.id;
            string type_label = frame.get_type_label();
            string fill_color = get_frame_color(frame.frame_type);

            // Build the cluster label with type and condition/label
            string cluster_label = type_label;
            if (frame.condition != null && frame.condition.length > 0) {
                cluster_label = "%s [%s]".printf(type_label, escape_label(frame.condition));
            } else if (frame.label != null && frame.label.length > 0) {
                cluster_label = "%s %s".printf(type_label, escape_label(frame.label));
            }

            // Create cluster subgraph
            sb.append("  subgraph cluster_%s {\n".printf(frame_id));
            sb.append("    label=\"%s\";\n".printf(cluster_label));
            sb.append("    labeljust=l;\n");  // Left-justify label
            sb.append("    style=filled;\n");
            sb.append("    fillcolor=\"%s\";\n".printf(fill_color));
            sb.append("    color=\"#888888\";\n");  // Border color
            sb.append("    fontname=\"Sans Bold\";\n");
            sb.append("    fontsize=10;\n");

            // Find messages that belong to this frame (between start_order and end_order)
            int msg_idx = 0;
            foreach (var msg in diagram.messages) {
                // Check if this message is within the frame's range
                // We use the event order to determine containment
                bool in_frame = is_message_in_frame(diagram, msg, frame);
                if (in_frame) {
                    sb.append("    msg%d;\n".printf(msg_idx));
                }
                msg_idx++;
            }

            // Render else sections within alt frames
            foreach (var section in frame.sections) {
                render_else_section(sb, section, diagram);
            }

            sb.append("  }\n");
        }

        private void render_else_section(StringBuilder sb, SequenceFrame section, SequenceDiagram diagram) {
            string section_label = "else";
            if (section.condition != null && section.condition.length > 0) {
                section_label = "else [%s]".printf(escape_label(section.condition));
            }

            // Create a sub-cluster for the else section
            sb.append("    subgraph cluster_%s {\n".printf(section.id));
            sb.append("      label=\"%s\";\n".printf(section_label));
            sb.append("      labeljust=l;\n");
            sb.append("      style=filled;\n");
            sb.append("      fillcolor=\"#F8F8F8\";\n");
            sb.append("      color=\"#AAAAAA\";\n");
            sb.append("      fontname=\"Sans\";\n");
            sb.append("      fontsize=9;\n");
            sb.append("    }\n");
        }

        private bool is_message_in_frame(SequenceDiagram diagram, Message msg, SequenceFrame frame) {
            // Find the order of this message in the events list
            foreach (var evt in diagram.events) {
                if (evt is MessageEvent) {
                    var msg_evt = (MessageEvent) evt;
                    if (msg_evt.message == msg) {
                        return msg_evt.order > frame.start_order && msg_evt.order < frame.end_order;
                    }
                }
            }
            return false;
        }

        private string get_frame_color(SequenceFrameType frame_type) {
            switch (frame_type) {
                case SequenceFrameType.ALT:
                    return "#FFFACD";  // Light yellow
                case SequenceFrameType.OPT:
                    return "#E6F3FF";  // Light blue
                case SequenceFrameType.LOOP:
                    return "#E8F5E9";  // Light green
                case SequenceFrameType.PAR:
                    return "#FFF3E0";  // Light orange
                case SequenceFrameType.BREAK:
                    return "#FFEBEE";  // Light red
                case SequenceFrameType.CRITICAL:
                    return "#FCE4EC";  // Light pink
                case SequenceFrameType.REF:
                    return "#F3E5F5";  // Light purple
                default:
                    return "#F5F5F5";  // Light gray for group
            }
        }

        private string escape_id(string s) {
            if (s == null || s.length == 0) {
                return "n_empty";
            }

            // Make valid DOT identifier - properly handle UTF-8
            var sb = new StringBuilder();
            unichar c;
            int i = 0;
            while (s.get_next_char(ref i, out c)) {
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '_') {
                    sb.append_unichar(c);
                } else {
                    sb.append_c('_');
                }
            }
            string result = sb.str;
            if (result.length == 0 || (result[0] >= '0' && result[0] <= '9')) {
                return "n_" + result;
            }
            return result;
        }

        private string escape_label(string? s) {
            if (s == null || s.length == 0) {
                return "";
            }

            // Validate UTF-8 and copy to a clean string
            if (!s.validate()) {
                // If invalid UTF-8, convert to safe ASCII representation
                var safe_sb = new StringBuilder();
                for (int i = 0; i < s.length; i++) {
                    char c = s[i];
                    if (c >= 32 && c < 127) {
                        safe_sb.append_c(c);
                    } else {
                        safe_sb.append_c('?');
                    }
                }
                return safe_sb.str;
            }

            // Build result by iterating over UTF-8 characters properly
            var sb = new StringBuilder();
            unichar c;
            int i = 0;
            while (s.get_next_char(ref i, out c)) {
                if (c == '\\') {
                    // Check for \n escape sequence
                    if (i < s.length) {
                        unichar next;
                        int next_i = i;
                        if (s.get_next_char(ref next_i, out next) && next == 'n') {
                            sb.append("\\n");  // Keep as escaped newline for DOT
                            i = next_i;
                            continue;
                        }
                    }
                    sb.append("\\\\");  // Escape backslash
                } else if (c == '"') {
                    sb.append("\\\"");  // Escape quote
                } else if (c == '\n') {
                    sb.append("\\n");   // Convert newline
                } else {
                    sb.append_unichar(c);
                }
            }

            return sb.str;
        }

        private bool has_creole_formatting(string? s) {
            if (s == null) return false;
            return s.contains("**") || s.contains("//") || s.contains("__") ||
                   s.contains("--") || s.contains("~~");
        }

        private string convert_creole_to_html(string? s) {
            if (s == null || s.length == 0) {
                return "";
            }
            // Convert Creole formatting to Graphviz HTML-like label format
            string result = s;
            string? temp;

            // Convert \n to <br/>
            temp = result.replace("\\n", "<br/>");
            if (temp != null) result = temp;

            // Escape HTML special characters first (but not our markers)
            temp = result.replace("&", "&amp;");
            if (temp != null) result = temp;

            // Note: Graphviz HTML labels should preserve regular spaces
            // Remove the &#160; conversion as it may not be supported

            // Convert Creole markers to HTML tags using regex
            try {
                // Bold: **text**
                Regex bold_re = new Regex("\\*\\*(.+?)\\*\\*");
                string? regex_temp = bold_re.replace(result, -1, 0, "<b>\\1</b>");
                if (regex_temp != null) result = regex_temp;

                // Italic: //text// - use non-greedy match
                Regex italic_re = new Regex("//(.+?)//");
                regex_temp = italic_re.replace(result, -1, 0, "<i>\\1</i>");
                if (regex_temp != null) result = regex_temp;

                // Underline: __text__
                Regex underline_re = new Regex("__(.+?)__");
                regex_temp = underline_re.replace(result, -1, 0, "<u>\\1</u>");
                if (regex_temp != null) result = regex_temp;

                // Strikethrough: --text--
                Regex strike_re = new Regex("--(.+?)--");
                regex_temp = strike_re.replace(result, -1, 0, "<s>\\1</s>");
                if (regex_temp != null) result = regex_temp;

                // Monospace: ~~text~~
                Regex mono_re = new Regex("~~(.+?)~~");
                regex_temp = mono_re.replace(result, -1, 0, "<font face=\"monospace\">\\1</font>");
                if (regex_temp != null) result = regex_temp;
            } catch (RegexError e) {
                // If regex fails, return original
            }

            // Wrap in TABLE structure to fix libgvc spacing issues with mixed HTML content
            result = "<TABLE BORDER=\"0\" CELLSPACING=\"0\" CELLPADDING=\"0\" CELLBORDER=\"0\"><TR><TD ALIGN=\"LEFT\">" + result + "</TD></TR></TABLE>";

            return result;
        }

        // Class Diagram rendering
        public string generate_class_dot(ClassDiagram diagram) {
            var sb = new StringBuilder();

            // Get theme values with defaults
            string bg_color = diagram.skin_params.background_color ?? "white";
            string class_bg = diagram.skin_params.get_element_property("class", "BackgroundColor") ?? "#FEFECE";
            string class_border = diagram.skin_params.get_element_property("class", "BorderColor") ?? "black";
            string class_font_color = diagram.skin_params.get_element_property("class", "FontColor") ?? "black";
            string font_name = diagram.skin_params.default_font_name ?? "Sans";
            string font_size = diagram.skin_params.default_font_size ?? "10";

            sb.append("digraph classes {\n");
            sb.append("  rankdir=TB;\n");
            sb.append("  bgcolor=\"%s\";\n".printf(bg_color));
            sb.append("  node [shape=record, style=filled, fillcolor=\"%s\", color=\"%s\", fontcolor=\"%s\", fontname=\"%s\", fontsize=%s];\n".printf(
                class_bg, class_border, class_font_color, font_name, font_size
            ));
            sb.append("  edge [fontsize=9, fontname=\"%s\"];\n".printf(font_name));
            sb.append("  splines=ortho;\n");

            // Title
            if (diagram.title != null) {
                sb.append("  label=\"%s\";\n".printf(escape_label(diagram.title)));
                sb.append("  labelloc=t;\n");
                sb.append("  fontsize=14;\n");
                sb.append("  fontname=\"%s\";\n".printf(font_name));
            }
            sb.append("\n");

            // Create class nodes
            sb.append("  // Classes\n");
            foreach (var c in diagram.classes) {
                string id = c.get_id();
                string label = build_class_label(c);
                if (c.color != null && c.color.length > 0) {
                    sb.append("  %s [label=\"%s\", fillcolor=\"%s\"];\n".printf(id, label, c.color));
                } else {
                    sb.append("  %s [label=\"%s\"];\n".printf(id, label));
                }
            }
            sb.append("\n");

            // Create notes
            if (diagram.notes.size > 0) {
                sb.append("  // Notes\n");
                string note_bg = diagram.skin_params.get_element_property("note", "BackgroundColor") ?? "#FFFFCC";
                string note_border = diagram.skin_params.get_element_property("note", "BorderColor") ?? "#A0A000";

                foreach (var note in diagram.notes) {
                    string note_label = escape_label(note.text);
                    sb.append("  %s [shape=note, label=\"%s\", fillcolor=\"%s\", color=\"%s\"];\n".printf(
                        note.id, note_label, note_bg, note_border
                    ));

                    // Connect note to class if attached
                    if (note.attached_to != null) {
                        var target_class = diagram.find_class(note.attached_to);
                        if (target_class != null) {
                            string rank = "";
                            if (note.position == "left" || note.position == "right") {
                                rank = "same";
                            }
                            sb.append("  %s -> %s [style=dashed, arrowhead=none, constraint=false];\n".printf(
                                note.id, target_class.get_id()
                            ));
                        }
                    }
                }
                sb.append("\n");
            }

            // Create relationship edges
            sb.append("  // Relationships\n");
            foreach (var rel in diagram.relationships) {
                string from_id = rel.from.get_id();
                string to_id = rel.to.get_id();
                string style = get_relationship_style(rel.relationship_type);
                string arrowhead = get_relationship_arrowhead(rel.relationship_type);
                string arrowtail = get_relationship_arrowtail(rel.relationship_type);
                string label = rel.label != null ? escape_label(rel.label) : "";

                sb.append("  %s -> %s [style=%s, arrowhead=%s, arrowtail=%s, dir=both".printf(
                    from_id, to_id, style, arrowhead, arrowtail
                ));
                if (label != "") {
                    sb.append(", label=\"%s\"".printf(label));
                }
                sb.append("];\n");
            }

            sb.append("}\n");

            return sb.str;
        }

        private string build_class_label(UmlClass c) {
            var sb = new StringBuilder();

            // Header with stereotype and class name
            sb.append("{");

            // Stereotype - class type or custom
            string stereotype = "";
            if (c.stereotype != null && c.stereotype.length > 0) {
                // Custom stereotype
                stereotype = "\\<\\<%s\\>\\>\\n".printf(escape_label(c.stereotype));
            } else {
                // Type-based stereotype
                switch (c.class_type) {
                    case ClassType.INTERFACE:
                        stereotype = "\\<\\<interface\\>\\>\\n";
                        break;
                    case ClassType.ABSTRACT:
                        stereotype = "\\<\\<abstract\\>\\>\\n";
                        break;
                    case ClassType.ENUM:
                        stereotype = "\\<\\<enum\\>\\>\\n";
                        break;
                    default:
                        break;
                }
            }

            sb.append(stereotype);
            sb.append(escape_label(c.name));

            // Members
            if (c.members.size > 0) {
                // Separate fields and methods
                var fields = new Gee.ArrayList<ClassMember>();
                var methods = new Gee.ArrayList<ClassMember>();

                foreach (var m in c.members) {
                    if (m.is_method) {
                        methods.add(m);
                    } else {
                        fields.add(m);
                    }
                }

                // Fields section
                sb.append("|");
                foreach (var f in fields) {
                    sb.append(f.get_visibility_symbol());
                    sb.append(" ");
                    sb.append(escape_label(f.name));
                    sb.append("\\l");
                }

                // Methods section
                sb.append("|");
                foreach (var m in methods) {
                    sb.append(m.get_visibility_symbol());
                    sb.append(" ");
                    sb.append(escape_label(m.name));
                    sb.append("\\l");
                }
            }

            sb.append("}");

            return sb.str;
        }

        private string get_relationship_style(RelationshipType type) {
            switch (type) {
                case RelationshipType.IMPLEMENTATION:
                case RelationshipType.DEPENDENCY:
                    return "dashed";
                default:
                    return "solid";
            }
        }

        private string get_relationship_arrowhead(RelationshipType type) {
            switch (type) {
                case RelationshipType.INHERITANCE:
                case RelationshipType.IMPLEMENTATION:
                    return "empty";
                case RelationshipType.DEPENDENCY:
                case RelationshipType.ASSOCIATION:
                    return "open";
                case RelationshipType.AGGREGATION:
                    return "none";
                case RelationshipType.COMPOSITION:
                    return "none";
                default:
                    return "open";
            }
        }

        private string get_relationship_arrowtail(RelationshipType type) {
            switch (type) {
                case RelationshipType.AGGREGATION:
                    return "odiamond";
                case RelationshipType.COMPOSITION:
                    return "diamond";
                default:
                    return "none";
            }
        }

        public uint8[]? render_class_to_svg(ClassDiagram diagram) {
            string dot = generate_class_dot(diagram);

            var graph = Gvc.Graph.read_string(dot);
            if (graph == null) {
                warning("Failed to parse DOT graph");
                return null;
            }

            int ret = context.layout(graph, layout_engine);
            if (ret != 0) {
                warning("Failed to layout graph with engine: %s", layout_engine);
                return null;
            }

            uint8[] svg_data;
            ret = context.render_data(graph, "svg", out svg_data);

            context.free_layout(graph);

            if (ret != 0) {
                warning("Failed to render graph");
                return null;
            }

            return svg_data;
        }

        public Cairo.ImageSurface? render_class_to_surface(ClassDiagram diagram) {
            uint8[]? svg_data = render_class_to_svg(diagram);
            if (svg_data == null) {
                return null;
            }

            // Build element line number map from diagram
            var element_lines = new Gee.HashMap<string, int>();
            foreach (var uml_class in diagram.classes) {
                if (uml_class.source_line > 0) {
                    element_lines.set(uml_class.name, uml_class.source_line);
                }
            }
            foreach (var note in diagram.notes) {
                if (note.source_line > 0) {
                    element_lines.set(note.id, note.source_line);
                    // Also map by first few words of note text for better matching
                    string short_text = note.text.length > 20 ? note.text.substring(0, 20) : note.text;
                    element_lines.set(short_text, note.source_line);
                }
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                // Parse SVG regions for click-to-source navigation (with pixel scaling)
                parse_svg_regions(svg_data, element_lines, width, height);

                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, (int)width, (int)height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                return surface;
            } catch (Error e) {
                warning("Failed to render SVG: %s", e.message);
                return null;
            }
        }

        public bool export_class_to_png(ClassDiagram diagram, string filename) {
            var surface = render_class_to_surface(diagram);
            if (surface == null) {
                return false;
            }

            var status = surface.write_to_png(filename);
            return status == Cairo.Status.SUCCESS;
        }

        public bool export_class_to_svg(ClassDiagram diagram, string filename) {
            uint8[]? svg_data = render_class_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var file = File.new_for_path(filename);
                var stream = file.replace(null, false, FileCreateFlags.NONE);
                stream.write_all(svg_data, null);
                stream.close();
                return true;
            } catch (Error e) {
                warning("Failed to write SVG: %s", e.message);
                return false;
            }
        }

        public bool export_class_to_pdf(ClassDiagram diagram, string filename) {
            uint8[]? svg_data = render_class_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                var surface = new Cairo.PdfSurface(filename, width, height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                surface.finish();

                return surface.status() == Cairo.Status.SUCCESS;
            } catch (Error e) {
                warning("Failed to export PDF: %s", e.message);
                return false;
            }
        }

        // Activity Diagram rendering
        public string generate_activity_dot(ActivityDiagram diagram) {
            var sb = new StringBuilder();

            // Get theme values with defaults
            string bg_color = diagram.skin_params.background_color ?? "white";
            string font_name = diagram.skin_params.default_font_name ?? "Sans";
            string font_size = diagram.skin_params.default_font_size ?? "10";
            string font_color = diagram.skin_params.default_font_color ?? "black";
            string arrow_color = diagram.skin_params.get_element_property("arrow", "Color") ?? "black";
            string arrow_font_color = diagram.skin_params.get_element_property("arrow", "FontColor") ?? font_color;

            // Store skin_params in a local variable for use in helper methods
            this.current_skin_params = diagram.skin_params;

            sb.append("digraph activity {\n");
            sb.append("  rankdir=TB;\n");
            sb.append("  bgcolor=\"%s\";\n".printf(bg_color));
            sb.append("  node [fontname=\"%s\", fontsize=%s, fontcolor=\"%s\"];\n".printf(font_name, font_size, font_color));
            sb.append("  edge [fontname=\"%s\", fontsize=9, color=\"%s\", fontcolor=\"%s\"];\n".printf(font_name, arrow_color, arrow_font_color));
            sb.append("  compound=true;\n");

            // Add title/header at top
            if ((diagram.title != null && diagram.title.length > 0) ||
                (diagram.header != null && diagram.header.length > 0)) {
                sb.append("  labelloc=\"t\";\n");
                var label_parts = new Gee.ArrayList<string>();
                if (diagram.header != null && diagram.header.length > 0) {
                    label_parts.add(escape_label(diagram.header));
                }
                if (diagram.title != null && diagram.title.length > 0) {
                    label_parts.add(escape_label(diagram.title));
                }
                sb.append("  label=\"%s\";\n".printf(string.joinv("\\n", label_parts.to_array())));
                sb.append("  fontsize=14;\n");
                sb.append("  fontname=\"Sans Bold\";\n");
            }

            // Add footer at bottom using xlabel on a dummy node
            if (diagram.footer != null && diagram.footer.length > 0) {
                // We'll add a footer node at the end
            }

            sb.append("\n");

            // Group nodes by partition
            var partition_nodes = new Gee.HashMap<string, Gee.ArrayList<ActivityNode>>();
            var no_partition_nodes = new Gee.ArrayList<ActivityNode>();

            foreach (var node in diagram.nodes) {
                if (node.partition != null && node.partition.length > 0) {
                    if (!partition_nodes.has_key(node.partition)) {
                        partition_nodes.set(node.partition, new Gee.ArrayList<ActivityNode>());
                    }
                    partition_nodes.get(node.partition).add(node);
                } else {
                    no_partition_nodes.add(node);
                }
            }

            // Render partitions as subgraphs (clusters)
            int cluster_idx = 0;
            foreach (var entry in partition_nodes.entries) {
                // Find partition and its display name/color
                string fill_color = "#E8E8E8";
                string border_color = "#888888";
                string display_name = entry.key;
                foreach (var p in diagram.partitions) {
                    // Match by name or alias
                    if (p.name == entry.key || (p.alias != null && p.alias == entry.key)) {
                        display_name = p.name;  // Use display name
                        if (p.color != null) {
                            fill_color = p.color;
                            border_color = p.color;
                        }
                        break;
                    }
                }

                sb.append("  subgraph cluster_%d {\n".printf(cluster_idx));
                sb.append("    label=\"%s\";\n".printf(escape_label(display_name)));
                sb.append("    style=filled;\n");
                sb.append("    fillcolor=\"%s\";\n".printf(fill_color));
                sb.append("    color=\"%s\";\n".printf(border_color));
                sb.append("\n");

                foreach (var node in entry.value) {
                    sb.append("  ");
                    append_activity_node(sb, node);
                }

                sb.append("  }\n\n");
                cluster_idx++;
            }

            // Render nodes without partitions
            sb.append("  // Nodes without partition\n");
            foreach (var node in no_partition_nodes) {
                append_activity_node(sb, node);
            }
            sb.append("\n");

            // Create edges
            sb.append("  // Edges\n");
            foreach (var edge in diagram.edges) {
                string label = edge.label != null ? escape_label(edge.label) : "";

                // Check for multi-colored arrows (semicolon-separated colors)
                string[]? multi_colors = null;
                if (edge.color != null && edge.color.contains(";")) {
                    multi_colors = edge.color.split(";");
                }

                if (multi_colors != null && multi_colors.length > 1) {
                    // Create multiple parallel edges for multi-colored arrows
                    int color_count = multi_colors.length;
                    for (int i = 0; i < color_count; i++) {
                        var attrs = new Gee.ArrayList<string>();
                        string c = multi_colors[i].strip();

                        // Only first edge gets the label
                        if (i == 0 && label != "") {
                            attrs.add("label=\"%s\"".printf(label));
                        }

                        if (c.length > 0) {
                            attrs.add("color=\"%s\"".printf(c));
                            if (i == 0) {
                                attrs.add("fontcolor=\"%s\"".printf(c));
                            }
                        }

                        if (edge.style != null && edge.style.length > 0) {
                            string gv_style = edge.style == "hidden" ? "invis" : edge.style;
                            attrs.add("style=\"%s\"".printf(gv_style));
                        }

                        // Note only on first edge
                        if (i == 0 && edge.note != null && edge.note.length > 0) {
                            attrs.add("xlabel=\"%s\"".printf(escape_label(edge.note)));
                        }

                        // Direction hints
                        switch (edge.direction) {
                            case EdgeDirection.UP:
                                attrs.add("dir=back");
                                break;
                            case EdgeDirection.LEFT:
                            case EdgeDirection.RIGHT:
                                attrs.add("constraint=false");
                                break;
                            default:
                                break;
                        }

                        // Use constraint=false for non-first edges to allow parallel placement
                        if (i > 0) {
                            attrs.add("constraint=false");
                        }

                        sb.append("  %s -> %s [%s];\n".printf(
                            edge.from.id, edge.to.id, string.joinv(", ", attrs.to_array())
                        ));
                    }
                } else {
                    // Single color edge (original behavior)
                    var attrs = new Gee.ArrayList<string>();

                    if (label != "") {
                        attrs.add("label=\"%s\"".printf(label));
                    }
                    if (edge.color != null && edge.color.length > 0) {
                        attrs.add("color=\"%s\"".printf(edge.color));
                        attrs.add("fontcolor=\"%s\"".printf(edge.color));
                    }
                    if (edge.style != null && edge.style.length > 0) {
                        // Convert PlantUML "hidden" to Graphviz "invis"
                        string gv_style = edge.style == "hidden" ? "invis" : edge.style;
                        attrs.add("style=\"%s\"".printf(gv_style));
                    }

                    // Note on link - displayed as xlabel (external label)
                    if (edge.note != null && edge.note.length > 0) {
                        attrs.add("xlabel=\"%s\"".printf(escape_label(edge.note)));
                    }

                    // Handle direction hints
                    switch (edge.direction) {
                        case EdgeDirection.UP:
                            attrs.add("dir=back");
                            break;
                        case EdgeDirection.LEFT:
                        case EdgeDirection.RIGHT:
                            attrs.add("constraint=false");
                            break;
                        default:
                            break;
                    }

                    if (attrs.size > 0) {
                        sb.append("  %s -> %s [%s];\n".printf(
                            edge.from.id, edge.to.id, string.joinv(", ", attrs.to_array())
                        ));
                    } else {
                        sb.append("  %s -> %s;\n".printf(edge.from.id, edge.to.id));
                    }
                }
            }

            // Create notes
            if (diagram.notes.size > 0) {
                sb.append("\n  // Notes\n");
                foreach (var note in diagram.notes) {
                    bool use_html = has_creole_formatting(note.text);
                    string note_label;

                    if (use_html) {
                        note_label = convert_creole_to_html(note.text);
                    } else {
                        note_label = escape_label(note.text);
                        // Replace \n with \\n for Graphviz label
                        string? temp_label = note_label.replace("\n", "\\n");
                        if (temp_label != null) note_label = temp_label;
                    }

                    // Use custom color or theme color or default yellow
                    string note_default = "#FFFFCC";
                    if (current_skin_params != null) {
                        note_default = current_skin_params.get_element_property("note", "BackgroundColor") ?? "#FFFFCC";
                    }
                    string note_color = note.color != null ? note.color : note_default;

                    if (use_html) {
                        sb.append("  %s [shape=note, style=filled, fillcolor=\"%s\", label=<%s>];\n".printf(
                            note.id, note_color, note_label
                        ));
                    } else {
                        sb.append("  %s [shape=note, style=filled, fillcolor=\"%s\", label=\"%s\"];\n".printf(
                            note.id, note_color, note_label
                        ));
                    }

                    // Connect note to attached node
                    if (note.attached_to != null) {
                        switch (note.position) {
                            case NotePosition.LEFT:
                                // Note on left: note -> node (note comes first)
                                sb.append("  %s -> %s [style=invis];\n".printf(
                                    note.id, note.attached_to.id
                                ));
                                // Dashed connector line
                                sb.append("  %s -> %s [style=dashed, arrowhead=none, constraint=false];\n".printf(
                                    note.attached_to.id, note.id
                                ));
                                // Same rank to keep horizontal
                                sb.append("  { rank=same; %s; %s; }\n".printf(
                                    note.attached_to.id, note.id
                                ));
                                break;

                            case NotePosition.RIGHT:
                                // Note on right: node -> note (node comes first)
                                sb.append("  %s -> %s [style=invis];\n".printf(
                                    note.attached_to.id, note.id
                                ));
                                // Dashed connector line
                                sb.append("  %s -> %s [style=dashed, arrowhead=none, constraint=false];\n".printf(
                                    note.attached_to.id, note.id
                                ));
                                // Same rank to keep horizontal
                                sb.append("  { rank=same; %s; %s; }\n".printf(
                                    note.attached_to.id, note.id
                                ));
                                break;

                            case NotePosition.TOP:
                                // Note above: note -> node (vertical ordering)
                                sb.append("  %s -> %s [style=dashed, arrowhead=none];\n".printf(
                                    note.id, note.attached_to.id
                                ));
                                break;

                            case NotePosition.BOTTOM:
                                // Note below: node -> note (vertical ordering)
                                sb.append("  %s -> %s [style=dashed, arrowhead=none];\n".printf(
                                    note.attached_to.id, note.id
                                ));
                                break;
                        }
                    }
                }
            }

            // Add footer as a label node at the bottom
            string? connect_from = null;
            if (diagram.nodes.size > 0) {
                connect_from = diagram.nodes.get(diagram.nodes.size - 1).id;
            }

            if (diagram.footer != null && diagram.footer.length > 0) {
                sb.append("\n  // Footer\n");
                sb.append("  footer [shape=plaintext, label=\"%s\", fontsize=10, fontname=\"Sans\"];\n".printf(
                    escape_label(diagram.footer)
                ));
                if (connect_from != null) {
                    sb.append("  %s -> footer [style=invis];\n".printf(connect_from));
                }
                connect_from = "footer";
            }

            // Add caption below footer (italic style)
            if (diagram.caption != null && diagram.caption.length > 0) {
                sb.append("\n  // Caption\n");
                sb.append("  caption [shape=plaintext, label=\"%s\", fontsize=9, fontname=\"Sans Italic\"];\n".printf(
                    escape_label(diagram.caption)
                ));
                if (connect_from != null) {
                    sb.append("  %s -> caption [style=invis];\n".printf(connect_from));
                }
            }

            // Add legend
            if (diagram.legend != null && diagram.legend.text.length > 0) {
                sb.append("\n  // Legend\n");
                bool legend_use_html = has_creole_formatting(diagram.legend.text);
                string legend_label;

                if (legend_use_html) {
                    legend_label = convert_creole_to_html(diagram.legend.text);
                    sb.append("  legend_node [shape=box, style=\"filled\", fillcolor=\"#FFFFCC\", ");
                    sb.append("label=<%s>, fontsize=9, fontname=\"Sans\"];\n".printf(legend_label));
                } else {
                    legend_label = escape_label(diagram.legend.text);
                    // Replace \n with \l for left-aligned lines in Graphviz
                    string? temp_legend = legend_label.replace("\n", "\\l");
                    if (temp_legend != null) legend_label = temp_legend;
                    sb.append("  legend_node [shape=box, style=\"filled\", fillcolor=\"#FFFFCC\", ");
                    sb.append("label=\"%s\\l\", fontsize=9, fontname=\"Sans\"];\n".printf(legend_label));
                }

                // Position based on legend position setting
                switch (diagram.legend.position) {
                    case LegendPosition.LEFT:
                        // Put legend on left side by constraining with first node
                        if (diagram.nodes.size > 0) {
                            sb.append("  { rank=same; legend_node; %s; }\n".printf(diagram.nodes.get(0).id));
                            sb.append("  legend_node -> %s [style=invis];\n".printf(diagram.nodes.get(0).id));
                        }
                        break;
                    case LegendPosition.RIGHT:
                        // Put legend on right side
                        if (diagram.nodes.size > 0) {
                            sb.append("  { rank=same; %s; legend_node; }\n".printf(diagram.nodes.get(0).id));
                            sb.append("  %s -> legend_node [style=invis];\n".printf(diagram.nodes.get(0).id));
                        }
                        break;
                    case LegendPosition.CENTER:
                        // Center: place at bottom
                        if (connect_from != null) {
                            sb.append("  %s -> legend_node [style=invis];\n".printf(connect_from));
                        }
                        break;
                }
            }

            sb.append("}\n");

            return sb.str;
        }

        private void append_activity_node(StringBuilder sb, ActivityNode node) {
            string shape = "";
            string label = "";
            string style = "";
            string width = "";
            string height = "";

            switch (node.node_type) {
                case ActivityNodeType.START:
                    shape = "circle";
                    style = "filled";
                    label = "";
                    width = "0.3";
                    height = "0.3";
                    sb.append("  %s [shape=%s, style=\"%s\", fillcolor=\"black\", label=\"\", width=%s, height=%s];\n".printf(
                        node.id, shape, style, width, height
                    ));
                    break;

                case ActivityNodeType.STOP:
                    shape = "doublecircle";
                    style = "filled";
                    label = "";
                    width = "0.3";
                    height = "0.3";
                    sb.append("  %s [shape=%s, style=\"%s\", fillcolor=\"black\", label=\"\", width=%s, height=%s];\n".printf(
                        node.id, shape, style, width, height
                    ));
                    break;

                case ActivityNodeType.END:
                    // End = flow final (bullseye - circle with filled circle inside)
                    sb.append("  %s [shape=doublecircle, style=\"filled\", fillcolor=\"black\", color=\"black\", label=\"\", width=0.2];\n".printf(
                        node.id
                    ));
                    break;

                case ActivityNodeType.KILL:
                    // Kill shows X symbol
                    shape = "circle";
                    style = "filled";
                    width = "0.25";
                    height = "0.25";
                    sb.append("  %s [shape=%s, style=\"%s\", fillcolor=\"black\", label=\"X\", fontcolor=\"white\", width=%s, height=%s];\n".printf(
                        node.id, shape, style, width, height
                    ));
                    break;

                case ActivityNodeType.DETACH:
                    // Detach is invisible - flow just ends
                    sb.append("  %s [shape=point, style=\"invis\", width=\"0\", height=\"0\"];\n".printf(
                        node.id
                    ));
                    break;

                case ActivityNodeType.ACTION:
                    string raw_label = node.label != null ? node.label : "";
                    bool use_html_label = has_creole_formatting(raw_label);

                    if (use_html_label) {
                        label = convert_creole_to_html(raw_label);
                        // Add stereotype above label if present
                        if (node.stereotype != null && node.stereotype.length > 0) {
                            label = "«" + node.stereotype + "»<br/>" + label;
                        }
                    } else {
                        label = escape_label(raw_label);
                        // Add stereotype above label if present
                        if (node.stereotype != null && node.stereotype.length > 0) {
                            label = "«" + escape_label(node.stereotype) + "»\\n" + label;
                        }
                    }

                    // Build fill color (support gradient with color2)
                    string fill_color;
                    string gradient_attr = "";
                    // Get default action color from theme
                    string default_action_color = "#FEFECE";
                    if (current_skin_params != null) {
                        default_action_color = current_skin_params.get_element_property("activity", "BackgroundColor") ?? "#FEFECE";
                    }
                    if (node.color2 != null && node.color2.length > 0) {
                        // Gradient: color1:color2
                        string c1 = node.color != null ? node.color : default_action_color;
                        fill_color = c1 + ":" + node.color2;
                        gradient_attr = ", gradientangle=270";
                    } else {
                        fill_color = node.color != null ? node.color : default_action_color;
                    }

                    // Determine shape based on SDL shape type
                    switch (node.shape) {
                        case ActionShape.SDL_TASK:
                            shape = "box";
                            style = "filled";
                            break;
                        case ActionShape.SDL_INPUT:
                            // Box shape for input
                            shape = "box";
                            style = "filled";
                            break;
                        case ActionShape.SDL_OUTPUT:
                            // Box shape for output
                            shape = "box";
                            style = "filled";
                            break;
                        case ActionShape.SDL_SAVE:
                            // Parallelogram leaning right
                            shape = "polygon";
                            style = "filled";
                            break;
                        case ActionShape.SDL_LOAD:
                            // Parallelogram leaning left (mirrored save)
                            shape = "polygon";
                            style = "filled";
                            break;
                        case ActionShape.SDL_PROCEDURE:
                            shape = "box";
                            style = "filled";
                            // Add double lines for procedure
                            string proc_border = node.line_color != null ? ", color=\"%s\"".printf(node.line_color) : "";
                            string proc_font = node.text_color != null ? ", fontcolor=\"%s\"".printf(node.text_color) : "";
                            string proc_url = node.url != null ? ", URL=\"%s\"".printf(node.url) : "";
                            if (use_html_label) {
                                sb.append("  %s [shape=%s, style=\"%s\", fillcolor=\"%s\", label=<%s>, peripheries=2%s%s%s%s];\n".printf(
                                    node.id, shape, style, fill_color, label, gradient_attr, proc_border, proc_font, proc_url
                                ));
                            } else {
                                sb.append("  %s [shape=%s, style=\"%s\", fillcolor=\"%s\", label=\"%s\", peripheries=2%s%s%s%s];\n".printf(
                                    node.id, shape, style, fill_color, label, gradient_attr, proc_border, proc_font, proc_url
                                ));
                            }
                            break;
                        default:
                            shape = "box";
                            style = "filled,rounded";
                            break;
                    }

                    if (node.shape != ActionShape.SDL_PROCEDURE) {
                        string border_attr = node.line_color != null ? ", color=\"%s\"".printf(node.line_color) : "";
                        string font_attr = node.text_color != null ? ", fontcolor=\"%s\"".printf(node.text_color) : "";
                        string url_attr = node.url != null ? ", URL=\"%s\"".printf(node.url) : "";
                        // Polygon attributes for parallelograms
                        string skew_attr = "";
                        if (node.shape == ActionShape.SDL_SAVE) {
                            skew_attr = ", sides=4, skew=0.4";  // Leaning right
                        } else if (node.shape == ActionShape.SDL_LOAD) {
                            skew_attr = ", sides=4, skew=-0.4";  // Leaning left (mirrored)
                        }
                        if (use_html_label) {
                            sb.append("  %s [shape=%s, style=\"%s\", fillcolor=\"%s\", label=<%s>%s%s%s%s%s];\n".printf(
                                node.id, shape, style, fill_color, label, gradient_attr, border_attr, font_attr, url_attr, skew_attr
                            ));
                        } else {
                            sb.append("  %s [shape=%s, style=\"%s\", fillcolor=\"%s\", label=\"%s\"%s%s%s%s%s];\n".printf(
                                node.id, shape, style, fill_color, label, gradient_attr, border_attr, font_attr, url_attr, skew_attr
                            ));
                        }
                    }
                    break;

                case ActivityNodeType.CONDITION:
                    shape = "diamond";
                    style = "filled";
                    label = node.label != null ? escape_label(node.label) : "";
                    // Get condition color from theme or node
                    string cond_default = "#FEFECE";
                    if (current_skin_params != null) {
                        cond_default = current_skin_params.get_element_property("activity", "BackgroundColor") ?? "#FEFECE";
                    }
                    string cond_color = node.color != null ? node.color : cond_default;
                    sb.append("  %s [shape=%s, style=\"%s\", fillcolor=\"%s\", label=\"%s\"];\n".printf(
                        node.id, shape, style, cond_color, label
                    ));
                    break;

                case ActivityNodeType.FORK:
                case ActivityNodeType.JOIN:
                    shape = "box";
                    style = "filled";
                    width = "1.5";
                    height = "0.05";
                    string bar_color = node.color != null ? node.color : "black";
                    sb.append("  %s [shape=%s, style=\"%s\", fillcolor=\"%s\", label=\"\", width=%s, height=%s];\n".printf(
                        node.id, shape, style, bar_color, width, height
                    ));
                    break;

                case ActivityNodeType.MERGE:
                    shape = "point";
                    width = "0.1";
                    height = "0.1";
                    sb.append("  %s [shape=%s, width=%s, height=%s];\n".printf(
                        node.id, shape, width, height
                    ));
                    break;

                case ActivityNodeType.CONNECTOR:
                    shape = "circle";
                    style = "filled";
                    label = node.label != null ? escape_label(node.label) : "";
                    sb.append("  %s [shape=%s, style=\"%s\", fillcolor=\"#FFFFCC\", label=\"%s\", width=\"0.4\", height=\"0.4\"];\n".printf(
                        node.id, shape, style, label
                    ));
                    break;

                case ActivityNodeType.SEPARATOR:
                    // Horizontal line separator with optional label
                    if (node.label != null && node.label.length > 0) {
                        // Separator with text - use box with label
                        string sep_label = escape_label(node.label);
                        sb.append("  %s [shape=box, style=\"filled,rounded\", fillcolor=\"#E8E8E8\", color=\"#888888\", fontcolor=\"#555555\", label=\"%s\", width=\"2.0\"];\n".printf(
                            node.id, sep_label
                        ));
                    } else {
                        sb.append("  %s [shape=box, style=\"filled\", fillcolor=\"#888888\", label=\"\", width=\"2.0\", height=\"0.02\"];\n".printf(
                            node.id
                        ));
                    }
                    break;

                case ActivityNodeType.VSPACE:
                    // Invisible node for vertical spacing
                    sb.append("  %s [shape=point, width=\"0\", height=\"0.5\", style=\"invis\"];\n".printf(
                        node.id
                    ));
                    break;

                default:
                    shape = "box";
                    label = node.label != null ? escape_label(node.label) : "";
                    sb.append("  %s [shape=%s, label=\"%s\"];\n".printf(
                        node.id, shape, label
                    ));
                    break;
            }
        }

        public uint8[]? render_activity_to_svg(ActivityDiagram diagram) {
            string dot = generate_activity_dot(diagram);

            // Use command line dot instead of libgvc to fix HTML label rendering issues
            try {
                string tmp_dot = "/tmp/gplantuml_activity.dot";
                string tmp_svg = "/tmp/gplantuml_activity.svg";

                FileUtils.set_contents(tmp_dot, dot);

                string[] argv = {layout_engine, "-Tsvg", tmp_dot, "-o", tmp_svg};
                int exit_status;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);

                if (exit_status != 0) {
                    warning("dot command failed with exit status %d", exit_status);
                    return null;
                }

                uint8[] svg_data;
                FileUtils.get_data(tmp_svg, out svg_data);
                return svg_data;
            } catch (Error e) {
                warning("Failed to render with dot command: %s", e.message);
                return null;
            }
        }

        public Cairo.ImageSurface? render_activity_to_surface(ActivityDiagram diagram) {
            uint8[]? svg_data = render_activity_to_svg(diagram);
            if (svg_data == null) {
                return null;
            }

            // Post-process SVG to fix RSVG whitespace handling
            // Add xml:space="preserve" to text elements
            string svg_str = (string) svg_data;
            if (svg_str != null && svg_str.length > 0) {
                svg_str = svg_str.replace("<text ", "<text xml:space=\"preserve\" ");
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_str.data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                // Build element line number map from activity nodes
                var element_lines = new Gee.HashMap<string, int>();
                foreach (var node in diagram.nodes) {
                    if (node.source_line > 0) {
                        element_lines.set(node.id, node.source_line);
                        // Also map by label for action nodes
                        if (node.label != null && node.label.length > 0) {
                            element_lines.set(node.label, node.source_line);
                        }
                    }
                }

                // Parse SVG regions for click-to-source navigation (with pixel scaling)
                parse_svg_regions(svg_data, element_lines, width, height);

                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, (int)width, (int)height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                return surface;
            } catch (Error e) {
                warning("Failed to render SVG: %s", e.message);
                return null;
            }
        }

        public bool export_activity_to_png(ActivityDiagram diagram, string filename) {
            var surface = render_activity_to_surface(diagram);
            if (surface == null) {
                return false;
            }

            var status = surface.write_to_png(filename);
            return status == Cairo.Status.SUCCESS;
        }

        public bool export_activity_to_svg(ActivityDiagram diagram, string filename) {
            uint8[]? svg_data = render_activity_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var file = File.new_for_path(filename);
                var stream = file.replace(null, false, FileCreateFlags.NONE);
                stream.write_all(svg_data, null);
                stream.close();
                return true;
            } catch (Error e) {
                warning("Failed to write SVG: %s", e.message);
                return false;
            }
        }

        public bool export_activity_to_pdf(ActivityDiagram diagram, string filename) {
            uint8[]? svg_data = render_activity_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                var surface = new Cairo.PdfSurface(filename, width, height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                surface.finish();

                return surface.status() == Cairo.Status.SUCCESS;
            } catch (Error e) {
                warning("Failed to export PDF: %s", e.message);
                return false;
            }
        }

        // ==================== Use Case Diagram Rendering ====================

        public string generate_usecase_dot(UseCaseDiagram diagram) {
            var sb = new StringBuilder();

            // Get theme values with defaults
            string bg_color = diagram.skin_params.background_color ?? "white";
            string font_name = diagram.skin_params.default_font_name ?? "Sans";
            string font_size = diagram.skin_params.default_font_size ?? "10";
            string font_color = diagram.skin_params.default_font_color ?? "black";

            sb.append("digraph usecase {\n");
            sb.append("  rankdir=%s;\n".printf(diagram.left_to_right ? "LR" : "TB"));
            sb.append("  bgcolor=\"%s\";\n".printf(bg_color));
            sb.append("  node [fontname=\"%s\", fontsize=%s, fontcolor=\"%s\"];\n".printf(font_name, font_size, font_color));
            sb.append("  edge [fontname=\"%s\", fontsize=9];\n".printf(font_name));
            sb.append("  compound=true;\n");

            // Add title if present
            if (diagram.title != null && diagram.title.length > 0) {
                sb.append("  labelloc=\"t\";\n");
                sb.append("  label=\"%s\";\n".printf(escape_label(diagram.title)));
                sb.append("  fontsize=14;\n");
                sb.append("  fontname=\"Sans Bold\";\n");
            }

            sb.append("\n");

            // Render actors (stick figures or simple shapes)
            string actor_color = diagram.skin_params.get_element_property("actor", "BackgroundColor") ?? "#FEFECE";
            string actor_border = diagram.skin_params.get_element_property("actor", "BorderColor") ?? "#A80036";

            sb.append("  // Actors\n");
            foreach (var actor in diagram.actors) {
                string id = sanitize_id(actor.get_id());
                string label = actor.name;
                string fill = actor.color ?? actor_color;
                // Use a simple shape for actors - stick figure would require custom SVG
                sb.append("  %s [label=\"%s\", shape=ellipse, style=filled, fillcolor=\"%s\", color=\"%s\"];\n".printf(
                    id, escape_label(label), fill, actor_border));
            }

            // Render use cases
            string uc_color = diagram.skin_params.get_element_property("usecase", "BackgroundColor") ?? "#FEFECE";
            string uc_border = diagram.skin_params.get_element_property("usecase", "BorderColor") ?? "#A80036";

            sb.append("\n  // Use Cases\n");
            foreach (var uc in diagram.use_cases) {
                string id = sanitize_id(uc.get_id());
                string label = uc.name;
                string fill = uc.color ?? uc_color;
                sb.append("  %s [label=\"%s\", shape=ellipse, style=filled, fillcolor=\"%s\", color=\"%s\"];\n".printf(
                    id, escape_label(label), fill, uc_border));
            }

            // Render packages/rectangles as clusters
            string pkg_color = diagram.skin_params.get_element_property("package", "BackgroundColor") ?? "#FEFECE";
            string pkg_border = diagram.skin_params.get_element_property("package", "BorderColor") ?? "#000000";
            string rect_color = diagram.skin_params.get_element_property("rectangle", "BackgroundColor") ?? "#FFFFFF";
            string rect_border = diagram.skin_params.get_element_property("rectangle", "BorderColor") ?? "#000000";

            int cluster_idx = 0;
            foreach (var pkg in diagram.packages) {
                string container_name = pkg.container_type == UseCaseContainerType.RECTANGLE ? "Rectangle" : "Package";
                string fill_color = pkg.container_type == UseCaseContainerType.RECTANGLE ? rect_color : pkg_color;
                string border_color = pkg.container_type == UseCaseContainerType.RECTANGLE ? rect_border : pkg_border;

                sb.append("\n  // %s: %s\n".printf(container_name, pkg.name));
                sb.append("  subgraph cluster_%d {\n".printf(cluster_idx));
                sb.append("    label=\"%s\";\n".printf(escape_label(pkg.name)));

                if (pkg.container_type == UseCaseContainerType.RECTANGLE) {
                    // Rectangle: system boundary style
                    sb.append("    style=\"filled\";\n");
                    sb.append("    fillcolor=\"%s\";\n".printf(fill_color));
                    sb.append("    color=\"%s\";\n".printf(border_color));
                    sb.append("    penwidth=2;\n");
                } else {
                    // Package: tab style (simulated with filled)
                    sb.append("    style=filled;\n");
                    sb.append("    fillcolor=\"%s\";\n".printf(fill_color));
                    sb.append("    color=\"%s\";\n".printf(border_color));
                }
                sb.append("\n");

                // Actors in container
                foreach (var actor in pkg.actors) {
                    string id = sanitize_id(actor.get_id());
                    string label = actor.name;
                    string fill = actor.color ?? actor_color;
                    sb.append("    %s [label=\"%s\", shape=ellipse, style=filled, fillcolor=\"%s\", color=\"%s\"];\n".printf(
                        id, escape_label(label), fill, actor_border));
                }

                // Use cases in container
                foreach (var uc in pkg.use_cases) {
                    string id = sanitize_id(uc.get_id());
                    string label = uc.name;
                    string fill = uc.color ?? uc_color;
                    sb.append("    %s [label=\"%s\", shape=ellipse, style=filled, fillcolor=\"%s\", color=\"%s\"];\n".printf(
                        id, escape_label(label), fill, uc_border));
                }

                sb.append("  }\n");
                cluster_idx++;
            }

            // Render notes
            string note_color = diagram.skin_params.get_element_property("note", "BackgroundColor") ?? "#FFFFCC";
            if (diagram.notes.size > 0) {
                sb.append("\n  // Notes\n");
                foreach (var note in diagram.notes) {
                    string note_id = sanitize_id(note.id);
                    sb.append("  %s [label=\"%s\", shape=note, style=filled, fillcolor=\"%s\"];\n".printf(
                        note_id, escape_label(note.text), note_color));

                    if (note.attached_to != null) {
                        string target_id = sanitize_id(note.attached_to);
                        sb.append("  %s -> %s [style=dotted, arrowhead=none];\n".printf(note_id, target_id));
                    }
                }
            }

            // Render relationships
            sb.append("\n  // Relationships\n");
            foreach (var rel in diagram.relationships) {
                string from_id = sanitize_id(rel.from_id);
                string to_id = sanitize_id(rel.to_id);

                string style = rel.is_dashed ? "dashed" : "solid";
                string arrowhead = "vee";

                // Handle different relationship types
                switch (rel.relation_type) {
                    case UseCaseRelationType.INCLUDE:
                        style = "dashed";
                        break;
                    case UseCaseRelationType.EXTEND:
                        style = "dashed";
                        break;
                    case UseCaseRelationType.GENERALIZATION:
                        arrowhead = "empty";
                        break;
                    default:
                        break;
                }

                if (rel.label != null && rel.label.length > 0) {
                    sb.append("  %s -> %s [label=\"%s\", style=%s, arrowhead=%s];\n".printf(
                        from_id, to_id, escape_label(rel.label), style, arrowhead));
                } else {
                    sb.append("  %s -> %s [style=%s, arrowhead=%s];\n".printf(
                        from_id, to_id, style, arrowhead));
                }
            }

            sb.append("}\n");

            return sb.str;
        }

        private string sanitize_id(string id) {
            if (id == null || id.length == 0) {
                return "_empty";
            }

            // Convert name to valid DOT identifier
            var sb = new StringBuilder();
            unichar c;
            int i = 0;
            while (id.get_next_char(ref i, out c)) {
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '_') {
                    sb.append_unichar(c);
                } else {
                    sb.append_c('_');
                }
            }
            string result = sb.str;
            // Ensure it doesn't start with a number
            if (result.length > 0 && result[0] >= '0' && result[0] <= '9') {
                result = "_" + result;
            }
            return result.length > 0 ? result : "_empty";
        }

        public uint8[]? render_usecase_to_svg(UseCaseDiagram diagram) {
            string dot = generate_usecase_dot(diagram);

            try {
                string tmp_dot = "/tmp/gplantuml_usecase.dot";
                string tmp_svg = "/tmp/gplantuml_usecase.svg";

                FileUtils.set_contents(tmp_dot, dot);

                string[] argv = {layout_engine, "-Tsvg", "-o", tmp_svg, tmp_dot};
                int exit_status;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);

                if (exit_status != 0) {
                    warning("dot command failed with status %d", exit_status);
                    return null;
                }

                uint8[] svg_data;
                FileUtils.get_data(tmp_svg, out svg_data);
                return svg_data;
            } catch (Error e) {
                warning("Failed to render use case diagram: %s", e.message);
                return null;
            }
        }

        public Cairo.ImageSurface? render_usecase_to_surface(UseCaseDiagram diagram) {
            uint8[]? svg_data = render_usecase_to_svg(diagram);
            if (svg_data == null) {
                return null;
            }

            string svg_str = (string) svg_data;
            if (svg_str != null && svg_str.length > 0) {
                svg_str = svg_str.replace("<text ", "<text xml:space=\"preserve\" ");
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_str.data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                // Build element line number map from actors and use cases
                var element_lines = new Gee.HashMap<string, int>();
                foreach (var actor in diagram.actors) {
                    if (actor.source_line > 0) {
                        element_lines.set(actor.name, actor.source_line);
                        if (actor.alias != null) {
                            element_lines.set(actor.alias, actor.source_line);
                        }
                    }
                }
                foreach (var uc in diagram.use_cases) {
                    if (uc.source_line > 0) {
                        element_lines.set(uc.name, uc.source_line);
                        if (uc.alias != null) {
                            element_lines.set(uc.alias, uc.source_line);
                        }
                    }
                }
                // Also check actors/use cases in packages
                foreach (var pkg in diagram.packages) {
                    foreach (var actor in pkg.actors) {
                        if (actor.source_line > 0) {
                            element_lines.set(actor.name, actor.source_line);
                            if (actor.alias != null) {
                                element_lines.set(actor.alias, actor.source_line);
                            }
                        }
                    }
                    foreach (var uc in pkg.use_cases) {
                        if (uc.source_line > 0) {
                            element_lines.set(uc.name, uc.source_line);
                            if (uc.alias != null) {
                                element_lines.set(uc.alias, uc.source_line);
                            }
                        }
                    }
                }

                // Parse SVG regions for click-to-source navigation (with pixel scaling)
                parse_svg_regions(svg_data, element_lines, width, height);

                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, (int)width, (int)height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                return surface;
            } catch (Error e) {
                warning("Failed to render SVG: %s", e.message);
                return null;
            }
        }

        public bool export_usecase_to_png(UseCaseDiagram diagram, string filename) {
            var surface = render_usecase_to_surface(diagram);
            if (surface == null) {
                return false;
            }

            var status = surface.write_to_png(filename);
            return status == Cairo.Status.SUCCESS;
        }

        public bool export_usecase_to_svg(UseCaseDiagram diagram, string filename) {
            uint8[]? svg_data = render_usecase_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var file = File.new_for_path(filename);
                var stream = file.replace(null, false, FileCreateFlags.NONE);
                stream.write_all(svg_data, null);
                stream.close();
                return true;
            } catch (Error e) {
                warning("Failed to write SVG: %s", e.message);
                return false;
            }
        }

        public bool export_usecase_to_pdf(UseCaseDiagram diagram, string filename) {
            uint8[]? svg_data = render_usecase_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                var surface = new Cairo.PdfSurface(filename, width, height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                surface.finish();

                return surface.status() == Cairo.Status.SUCCESS;
            } catch (Error e) {
                warning("Failed to export PDF: %s", e.message);
                return false;
            }
        }

        // ==================== State Diagram Rendering ====================

        public string generate_state_dot(StateDiagram diagram) {
            var sb = new StringBuilder();

            // Get theme values with defaults
            string bg_color = diagram.skin_params.background_color ?? "white";
            string font_name = diagram.skin_params.default_font_name ?? "Sans";
            string font_size = diagram.skin_params.default_font_size ?? "10";
            string font_color = diagram.skin_params.default_font_color ?? "black";

            sb.append("digraph state {\n");
            sb.append("  rankdir=TB;\n");
            sb.append("  bgcolor=\"%s\";\n".printf(bg_color));
            sb.append("  node [fontname=\"%s\", fontsize=%s, fontcolor=\"%s\"];\n".printf(font_name, font_size, font_color));
            sb.append("  edge [fontname=\"%s\", fontsize=9];\n".printf(font_name));
            sb.append("  compound=true;\n");

            // Add title if present
            if (diagram.title != null && diagram.title.length > 0) {
                sb.append("  labelloc=\"t\";\n");
                sb.append("  label=\"%s\";\n".printf(escape_label(diagram.title)));
                sb.append("  fontsize=14;\n");
                sb.append("  fontname=\"Sans Bold\";\n");
            }

            sb.append("\n");

            // Get state colors from theme
            string state_color = diagram.skin_params.get_element_property("state", "BackgroundColor") ?? "#FEFECE";
            string state_border = diagram.skin_params.get_element_property("state", "BorderColor") ?? "#A80036";

            // Render states
            sb.append("  // States\n");
            int cluster_idx = 0;
            foreach (var state in diagram.states) {
                append_state_node(sb, state, state_color, state_border, ref cluster_idx);
            }

            // Render transitions
            sb.append("\n  // Transitions\n");
            foreach (var trans in diagram.transitions) {
                string from_id = sanitize_id(trans.from.id);
                string to_id = sanitize_id(trans.to.id);

                string style = trans.is_dashed ? "dashed" : "solid";
                string label = trans.get_full_label();

                if (label.length > 0) {
                    sb.append("  %s -> %s [label=\"%s\", style=%s];\n".printf(
                        from_id, to_id, escape_label(label), style));
                } else {
                    sb.append("  %s -> %s [style=%s];\n".printf(from_id, to_id, style));
                }
            }

            // Render notes
            if (diagram.notes.size > 0) {
                sb.append("\n  // Notes\n");
                string note_color = diagram.skin_params.get_element_property("note", "BackgroundColor") ?? "#FFFFCC";

                foreach (var note in diagram.notes) {
                    string note_id = sanitize_id(note.id);
                    sb.append("  %s [label=\"%s\", shape=note, style=filled, fillcolor=\"%s\"];\n".printf(
                        note_id, escape_label(note.text), note_color));

                    if (note.attached_to != null) {
                        string attached_id = sanitize_id(note.attached_to);
                        sb.append("  %s -> %s [style=dashed, arrowhead=none];\n".printf(note_id, attached_id));
                    }
                }
            }

            sb.append("}\n");

            return sb.str;
        }

        private void append_state_node(StringBuilder sb, State state, string default_color,
                                        string default_border, ref int cluster_idx) {
            string id = sanitize_id(state.id);
            string fill_color = state.color ?? default_color;

            switch (state.state_type) {
                case StateType.INITIAL:
                    sb.append("  %s [label=\"\", shape=circle, style=filled, fillcolor=\"black\", width=0.2, height=0.2];\n".printf(id));
                    break;

                case StateType.FINAL:
                    sb.append("  %s [label=\"\", shape=doublecircle, style=filled, fillcolor=\"black\", width=0.2, height=0.2];\n".printf(id));
                    break;

                case StateType.COMPOSITE:
                    // Render as cluster subgraph
                    sb.append("\n  subgraph cluster_%d {\n".printf(cluster_idx++));
                    sb.append("    label=\"%s\";\n".printf(escape_label(state.get_display_label())));
                    sb.append("    style=rounded;\n");
                    sb.append("    color=\"%s\";\n".printf(default_border));
                    sb.append("    bgcolor=\"%s\";\n".printf(fill_color));

                    if (state.description != null && state.description.length > 0) {
                        sb.append("    // Description: %s\n".printf(state.description));
                    }

                    // Render nested states
                    foreach (var nested in state.nested_states) {
                        sb.append("  ");
                        append_state_node(sb, nested, default_color, default_border, ref cluster_idx);
                    }

                    // Render nested transitions
                    foreach (var trans in state.nested_transitions) {
                        string from_id = sanitize_id(trans.from.id);
                        string to_id = sanitize_id(trans.to.id);
                        string style = trans.is_dashed ? "dashed" : "solid";
                        string label = trans.get_full_label();

                        if (label.length > 0) {
                            sb.append("    %s -> %s [label=\"%s\", style=%s];\n".printf(
                                from_id, to_id, escape_label(label), style));
                        } else {
                            sb.append("    %s -> %s [style=%s];\n".printf(from_id, to_id, style));
                        }
                    }

                    sb.append("  }\n");
                    break;

                case StateType.CHOICE:
                    // Diamond shape for choice/decision point
                    sb.append("  %s [label=\"\", shape=diamond, style=filled, fillcolor=\"%s\", width=0.4, height=0.4];\n".printf(
                        id, fill_color));
                    break;

                case StateType.FORK:
                case StateType.JOIN:
                    // Horizontal bar for fork/join
                    sb.append("  %s [label=\"\", shape=box, style=filled, fillcolor=\"black\", width=1.5, height=0.05];\n".printf(id));
                    break;

                case StateType.END_STATE:
                    // Circle with X or bulls-eye for termination
                    sb.append("  %s [label=\"\", shape=doublecircle, style=filled, fillcolor=\"black\", width=0.25, height=0.25];\n".printf(id));
                    break;

                case StateType.HISTORY:
                    // Circle with H
                    sb.append("  %s [label=\"H\", shape=circle, style=filled, fillcolor=\"white\", width=0.3, height=0.3, fontsize=10];\n".printf(id));
                    break;

                case StateType.DEEP_HISTORY:
                    // Circle with H*
                    sb.append("  %s [label=\"H*\", shape=circle, style=filled, fillcolor=\"white\", width=0.3, height=0.3, fontsize=10];\n".printf(id));
                    break;

                case StateType.ENTRY_POINT:
                    // Small filled circle (entry point)
                    sb.append("  %s [label=\"\", shape=circle, style=filled, fillcolor=\"black\", width=0.15, height=0.15];\n".printf(id));
                    break;

                case StateType.EXIT_POINT:
                    // Circle with X
                    sb.append("  %s [label=\"X\", shape=circle, style=\"filled\", fillcolor=\"white\", fontcolor=\"black\", width=0.2, height=0.2, fontsize=8];\n".printf(id));
                    break;

                default:  // SIMPLE
                    string label = state.get_display_label();
                    // Build label with description and entry/exit actions
                    var label_parts = new StringBuilder();
                    label_parts.append(label);

                    if (state.description != null && state.description.length > 0) {
                        label_parts.append("\\n");
                        label_parts.append(state.description);
                    }
                    if (state.entry_action != null && state.entry_action.length > 0) {
                        label_parts.append("\\nentry / ");
                        label_parts.append(state.entry_action);
                    }
                    if (state.exit_action != null && state.exit_action.length > 0) {
                        label_parts.append("\\nexit / ");
                        label_parts.append(state.exit_action);
                    }

                    sb.append("  %s [label=\"%s\", shape=box, style=\"rounded,filled\", fillcolor=\"%s\", color=\"%s\"];\n".printf(
                        id, escape_label(label_parts.str), fill_color, default_border));
                    break;
            }
        }

        public uint8[]? render_state_to_svg(StateDiagram diagram) {
            string dot = generate_state_dot(diagram);

            try {
                string tmp_dot = "/tmp/gplantuml_state.dot";
                string tmp_svg = "/tmp/gplantuml_state.svg";

                FileUtils.set_contents(tmp_dot, dot);

                string[] argv = {layout_engine, "-Tsvg", "-o", tmp_svg, tmp_dot};
                int exit_status;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);

                if (exit_status != 0) {
                    warning("dot command failed with status %d", exit_status);
                    return null;
                }

                uint8[] svg_data;
                FileUtils.get_data(tmp_svg, out svg_data);
                return svg_data;
            } catch (Error e) {
                warning("Failed to render state diagram: %s", e.message);
                return null;
            }
        }

        public Cairo.ImageSurface? render_state_to_surface(StateDiagram diagram) {
            uint8[]? svg_data = render_state_to_svg(diagram);
            if (svg_data == null) {
                return null;
            }

            string svg_str = (string) svg_data;
            if (svg_str != null && svg_str.length > 0) {
                svg_str = svg_str.replace("<text ", "<text xml:space=\"preserve\" ");
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_str.data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                // Build element line number map from states
                var element_lines = new Gee.HashMap<string, int>();
                foreach (var state in diagram.states) {
                    if (state.source_line > 0) {
                        element_lines.set(state.id, state.source_line);
                        if (state.label != null && state.label.length > 0) {
                            element_lines.set(state.label, state.source_line);
                        }
                    }
                }

                // Parse SVG regions for click-to-source navigation (with pixel scaling)
                parse_svg_regions(svg_data, element_lines, width, height);

                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, (int)width, (int)height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                return surface;
            } catch (Error e) {
                warning("Failed to render SVG: %s", e.message);
                return null;
            }
        }

        public bool export_state_to_png(StateDiagram diagram, string filename) {
            var surface = render_state_to_surface(diagram);
            if (surface == null) {
                return false;
            }

            var status = surface.write_to_png(filename);
            return status == Cairo.Status.SUCCESS;
        }

        public bool export_state_to_svg(StateDiagram diagram, string filename) {
            uint8[]? svg_data = render_state_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var file = File.new_for_path(filename);
                var stream = file.replace(null, false, FileCreateFlags.NONE);
                stream.write_all(svg_data, null);
                stream.close();
                return true;
            } catch (Error e) {
                warning("Failed to write SVG: %s", e.message);
                return false;
            }
        }

        public bool export_state_to_pdf(StateDiagram diagram, string filename) {
            uint8[]? svg_data = render_state_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                var surface = new Cairo.PdfSurface(filename, width, height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                surface.finish();

                return surface.status() == Cairo.Status.SUCCESS;
            } catch (Error e) {
                warning("Failed to export PDF: %s", e.message);
                return false;
            }
        }

        // ==================== Component Diagram Rendering ====================

        public string generate_component_dot(ComponentDiagram diagram) {
            var sb = new StringBuilder();

            // Get theme values
            string bg_color = diagram.skin_params.background_color ?? "white";
            string font_name = diagram.skin_params.default_font_name ?? "Sans";
            string font_size = diagram.skin_params.default_font_size ?? "10";
            string font_color = diagram.skin_params.default_font_color ?? "black";

            sb.append("digraph component {\n");
            sb.append("  rankdir=%s;\n".printf(diagram.left_to_right ? "LR" : "TB"));
            sb.append("  bgcolor=\"%s\";\n".printf(bg_color));
            sb.append("  node [fontname=\"%s\", fontsize=%s, fontcolor=\"%s\"];\n".printf(font_name, font_size, font_color));
            sb.append("  edge [fontname=\"%s\", fontsize=9];\n".printf(font_name));
            sb.append("  compound=true;\n");

            // Add title if present
            if (diagram.title != null && diagram.title.length > 0) {
                sb.append("  labelloc=\"t\";\n");
                sb.append("  label=\"%s\";\n".printf(escape_label(diagram.title)));
                sb.append("  fontsize=14;\n");
                sb.append("  fontname=\"Sans Bold\";\n");
            }

            sb.append("\n");

            // Get colors from theme
            string comp_color = diagram.skin_params.get_element_property("component", "BackgroundColor") ?? "#FEFECE";
            string comp_border = diagram.skin_params.get_element_property("component", "BorderColor") ?? "#A80036";
            string iface_color = diagram.skin_params.get_element_property("interface", "BackgroundColor") ?? "#B4A7E5";
            string pkg_color = diagram.skin_params.get_element_property("package", "BackgroundColor") ?? "#DDDDDD";

            // Render components
            sb.append("  // Components\n");
            int cluster_idx = 0;
            foreach (var comp in diagram.components) {
                append_component_node(sb, comp, comp_color, comp_border, pkg_color, ref cluster_idx);
            }

            // Render standalone interfaces
            sb.append("\n  // Interfaces\n");
            foreach (var iface in diagram.interfaces) {
                string id = sanitize_id(iface.get_identifier());
                string label = escape_label(iface.get_display_label());
                sb.append("  %s [label=\"%s\", shape=circle, width=0.3, height=0.3, style=filled, fillcolor=\"%s\"];\n".printf(
                    id, label, iface_color));
            }

            // Render ports
            if (diagram.ports.size > 0) {
                sb.append("\n  // Ports\n");
                foreach (var port in diagram.ports) {
                    string id = sanitize_id(port.id);
                    string label = port.label != null ? escape_label(port.label) : "";
                    string shape = "square";
                    string fill_color = "#FFFFFF";

                    // Different colors for port types
                    switch (port.port_type) {
                        case PortType.IN:
                            fill_color = "#CCFFCC";  // Green - required/input
                            label = label.length > 0 ? "← " + label : "←";
                            break;
                        case PortType.OUT:
                            fill_color = "#FFCCCC";  // Red - provided/output
                            label = label.length > 0 ? label + " →" : "→";
                            break;
                        default:
                            fill_color = "#FFFFCC";  // Yellow - bidirectional
                            label = label.length > 0 ? "↔ " + label : "↔";
                            break;
                    }

                    sb.append("  %s [label=\"%s\", shape=%s, style=filled, fillcolor=\"%s\", width=0.3, height=0.3];\n".printf(
                        id, label, shape, fill_color));

                    // Connect port to parent component if specified
                    if (port.parent_component != null) {
                        string parent_id = sanitize_id(port.parent_component);
                        sb.append("  %s -> %s [style=dotted, arrowhead=none];\n".printf(id, parent_id));
                    }
                }
            }

            // Render relationships
            sb.append("\n  // Relationships\n");
            foreach (var rel in diagram.relationships) {
                string from_id = sanitize_id(rel.from_id);
                string to_id = sanitize_id(rel.to_id);

                string style = rel.is_dashed ? "dashed" : "solid";
                string arrowhead = rel.right_arrow ? "vee" : "none";
                string arrowtail = rel.left_arrow ? "vee" : "none";

                // Handle special relationship types
                switch (rel.relation_type) {
                    case ComponentRelationType.AGGREGATION:
                        arrowtail = "odiamond";
                        break;
                    case ComponentRelationType.COMPOSITION:
                        arrowtail = "diamond";
                        break;
                    default:
                        break;
                }

                var attrs = new StringBuilder();
                attrs.append("style=%s".printf(style));
                attrs.append(", arrowhead=%s".printf(arrowhead));
                if (arrowtail != "none") {
                    attrs.append(", arrowtail=%s, dir=both".printf(arrowtail));
                }

                if (rel.label != null && rel.label.length > 0) {
                    attrs.append(", label=\"%s\"".printf(escape_label(rel.label)));
                }

                if (rel.color != null) {
                    attrs.append(", color=\"%s\"".printf(rel.color));
                }

                sb.append("  %s -> %s [%s];\n".printf(from_id, to_id, attrs.str));
            }

            // Render notes
            if (diagram.notes.size > 0) {
                sb.append("\n  // Notes\n");
                string note_color = diagram.skin_params.get_element_property("note", "BackgroundColor") ?? "#FFFFCC";

                foreach (var note in diagram.notes) {
                    string note_id = sanitize_id(note.id);
                    sb.append("  %s [label=\"%s\", shape=note, style=filled, fillcolor=\"%s\"];\n".printf(
                        note_id, escape_label(note.text), note_color));

                    if (note.attached_to != null) {
                        string attached_id = sanitize_id(note.attached_to);
                        sb.append("  %s -> %s [style=dashed, arrowhead=none];\n".printf(note_id, attached_id));
                    }
                }
            }

            sb.append("}\n");

            return sb.str;
        }

        private void append_component_node(StringBuilder sb, Component comp, string default_color,
                                           string default_border, string pkg_color, ref int cluster_idx) {
            string id = sanitize_id(comp.get_identifier());
            string label = escape_label(comp.get_display_label());
            string fill_color = comp.color ?? default_color;

            if (comp.is_container || comp.children.size > 0) {
                // Render as cluster subgraph
                sb.append("\n  subgraph cluster_%d {\n".printf(cluster_idx++));
                sb.append("    label=\"%s\";\n".printf(label));

                // Style based on container type
                switch (comp.component_type) {
                    case ComponentType.CLOUD:
                        sb.append("    style=rounded;\n");
                        sb.append("    bgcolor=\"#E8E8E8\";\n");
                        break;
                    case ComponentType.DATABASE:
                        sb.append("    style=rounded;\n");
                        sb.append("    bgcolor=\"#CCFFCC\";\n");
                        break;
                    case ComponentType.FOLDER:
                        sb.append("    style=\"rounded,bold\";\n");
                        sb.append("    bgcolor=\"%s\";\n".printf(pkg_color));
                        break;
                    case ComponentType.FRAME:
                        sb.append("    style=solid;\n");
                        sb.append("    bgcolor=\"%s\";\n".printf(pkg_color));
                        break;
                    case ComponentType.NODE:
                        sb.append("    style=bold;\n");
                        sb.append("    bgcolor=\"#FFFFCC\";\n");
                        break;
                    default:
                        sb.append("    style=rounded;\n");
                        sb.append("    bgcolor=\"%s\";\n".printf(pkg_color));
                        break;
                }

                if (comp.stereotype != null) {
                    sb.append("    // Stereotype: <<%s>>\n".printf(comp.stereotype));
                }

                // Render children
                foreach (var child in comp.children) {
                    append_component_node(sb, child, default_color, default_border, pkg_color, ref cluster_idx);
                }

                sb.append("  }\n");
            } else {
                // Render as individual node
                string shape;
                string style = "filled";

                switch (comp.component_type) {
                    case ComponentType.DATABASE:
                        shape = "cylinder";
                        fill_color = comp.color ?? "#CCFFCC";
                        break;
                    case ComponentType.CLOUD:
                        shape = "ellipse";
                        fill_color = comp.color ?? "#E8E8E8";
                        break;
                    case ComponentType.ARTIFACT:
                        shape = "note";
                        break;
                    case ComponentType.STORAGE:
                        shape = "folder";
                        break;
                    case ComponentType.CARD:
                        shape = "box";
                        style = "filled,rounded";
                        break;
                    case ComponentType.AGENT:
                        shape = "box";
                        break;
                    case ComponentType.INTERFACE:
                        shape = "circle";
                        break;
                    case ComponentType.QUEUE:
                        shape = "box";
                        style = "filled";
                        fill_color = comp.color ?? "#E8E8FF";
                        break;
                    case ComponentType.BOUNDARY:
                        shape = "box";
                        style = "filled,rounded";
                        fill_color = comp.color ?? "#FFFFCC";
                        break;
                    case ComponentType.CONTROL:
                        shape = "circle";
                        fill_color = comp.color ?? "#CCFFCC";
                        break;
                    case ComponentType.ENTITY:
                        shape = "box";
                        style = "filled";
                        fill_color = comp.color ?? "#CCCCFF";
                        break;
                    case ComponentType.FILE:
                        shape = "note";
                        fill_color = comp.color ?? "#FFFFFF";
                        break;
                    case ComponentType.STACK:
                        shape = "box3d";
                        fill_color = comp.color ?? "#E8E8E8";
                        break;
                    default:
                        shape = "component";
                        break;
                }

                var attrs = new StringBuilder();
                attrs.append("label=\"%s\"".printf(label));
                attrs.append(", shape=%s".printf(shape));
                attrs.append(", style=\"%s\"".printf(style));
                attrs.append(", fillcolor=\"%s\"".printf(fill_color));
                attrs.append(", color=\"%s\"".printf(default_border));

                if (comp.stereotype != null) {
                    attrs.append(", xlabel=\"<<%s>>\"".printf(comp.stereotype));
                }

                sb.append("  %s [%s];\n".printf(id, attrs.str));
            }
        }

        public uint8[]? render_component_to_svg(ComponentDiagram diagram) {
            string dot = generate_component_dot(diagram);

            string[] argv = {layout_engine, "-Tsvg"};
            string std_out;
            string std_err;
            int exit_status;

            try {
                var proc = new Subprocess.newv(argv, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
                proc.communicate_utf8(dot, null, out std_out, out std_err);
                proc.wait(null);
                exit_status = proc.get_exit_status();

                if (exit_status != 0) {
                    warning("Graphviz dot failed: %s", std_err);
                    return null;
                }

                return std_out.data;
            } catch (Error e) {
                warning("Failed to run dot: %s", e.message);
                return null;
            }
        }

        public Cairo.ImageSurface? render_component_to_surface(ComponentDiagram diagram) {
            uint8[]? svg_data = render_component_to_svg(diagram);
            if (svg_data == null) {
                return null;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                // Build element line number map from components
                var element_lines = new Gee.HashMap<string, int>();
                foreach (var comp in diagram.components) {
                    if (comp.source_line > 0) {
                        element_lines.set(comp.id, comp.source_line);
                        if (comp.label != null && comp.label.length > 0) {
                            element_lines.set(comp.label, comp.source_line);
                        }
                        if (comp.alias != null && comp.alias.length > 0) {
                            element_lines.set(comp.alias, comp.source_line);
                        }
                    }
                }

                // Parse SVG regions for click-to-source navigation (with pixel scaling)
                parse_svg_regions(svg_data, element_lines, width, height);

                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, (int)width, (int)height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                return surface;
            } catch (Error e) {
                warning("Failed to render SVG: %s", e.message);
                return null;
            }
        }

        public bool export_component_to_png(ComponentDiagram diagram, string filename) {
            var surface = render_component_to_surface(diagram);
            if (surface == null) {
                return false;
            }

            var status = surface.write_to_png(filename);
            return status == Cairo.Status.SUCCESS;
        }

        public bool export_component_to_svg(ComponentDiagram diagram, string filename) {
            uint8[]? svg_data = render_component_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                FileUtils.set_data(filename, svg_data);
                return true;
            } catch (Error e) {
                warning("Failed to write SVG: %s", e.message);
                return false;
            }
        }

        public bool export_component_to_pdf(ComponentDiagram diagram, string filename) {
            uint8[]? svg_data = render_component_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                var surface = new Cairo.PdfSurface(filename, width, height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                surface.finish();

                return surface.status() == Cairo.Status.SUCCESS;
            } catch (Error e) {
                warning("Failed to export PDF: %s", e.message);
                return false;
            }
        }

        // ==================== Object Diagram Rendering ====================

        public string generate_object_dot(ObjectDiagram diagram) {
            var sb = new StringBuilder();

            // Get theme values
            string bg_color = diagram.skin_params.background_color ?? "white";
            string font_name = diagram.skin_params.default_font_name ?? "Sans";
            string font_size = diagram.skin_params.default_font_size ?? "10";
            string font_color = diagram.skin_params.default_font_color ?? "black";

            sb.append("digraph object {\n");
            sb.append("  rankdir=TB;\n");
            sb.append("  bgcolor=\"%s\";\n".printf(bg_color));
            sb.append("  node [fontname=\"%s\", fontsize=%s, fontcolor=\"%s\", shape=record];\n".printf(font_name, font_size, font_color));
            sb.append("  edge [fontname=\"%s\", fontsize=9];\n".printf(font_name));

            // Add title if present
            if (diagram.title != null && diagram.title.length > 0) {
                sb.append("  labelloc=\"t\";\n");
                sb.append("  label=\"%s\";\n".printf(escape_label(diagram.title)));
                sb.append("  fontsize=14;\n");
                sb.append("  fontname=\"Sans Bold\";\n");
            }

            sb.append("\n");

            // Get object colors from theme
            string obj_color = diagram.skin_params.get_element_property("object", "BackgroundColor") ?? "#FEFECE";
            string obj_border = diagram.skin_params.get_element_property("object", "BorderColor") ?? "#A80036";

            // Render objects
            sb.append("  // Objects\n");
            foreach (var obj in diagram.objects) {
                string id = obj.get_id();
                string fill = obj.color ?? obj_color;

                // Build record label
                var label_parts = new StringBuilder();
                label_parts.append("{");
                label_parts.append(escape_label(obj.get_display_label()));

                if (obj.fields.size > 0) {
                    label_parts.append("|");
                    bool first = true;
                    foreach (var field in obj.fields) {
                        if (!first) {
                            label_parts.append("\\l");
                        }
                        label_parts.append(escape_label(field.name));
                        label_parts.append(" = ");
                        label_parts.append(escape_label(field.value));
                        first = false;
                    }
                    label_parts.append("\\l");
                }

                label_parts.append("}");

                sb.append("  %s [label=\"%s\", style=filled, fillcolor=\"%s\", color=\"%s\"];\n".printf(
                    id, label_parts.str, fill, obj_border));
            }

            // Render notes
            if (diagram.notes.size > 0) {
                sb.append("\n  // Notes\n");
                string note_color = diagram.skin_params.get_element_property("note", "BackgroundColor") ?? "#FFFFCC";

                foreach (var note in diagram.notes) {
                    sb.append("  %s [label=\"%s\", shape=note, style=filled, fillcolor=\"%s\"];\n".printf(
                        note.id, escape_label(note.text), note_color));

                    if (note.attached_to != null) {
                        var target = diagram.find_object(note.attached_to);
                        if (target != null) {
                            sb.append("  %s -> %s [style=dashed, arrowhead=none];\n".printf(
                                note.id, target.get_id()));
                        }
                    }
                }
            }

            // Render links
            sb.append("\n  // Links\n");
            foreach (var link in diagram.links) {
                var from = diagram.find_object(link.from_id);
                var to = diagram.find_object(link.to_id);

                if (from == null || to == null) continue;

                string from_id = from.get_id();
                string to_id = to.get_id();
                string style = link.is_dashed ? "dashed" : "solid";
                string arrowhead = "vee";
                string arrowtail = "none";

                switch (link.link_type) {
                    case ObjectLinkType.AGGREGATION:
                        arrowtail = "odiamond";
                        break;
                    case ObjectLinkType.COMPOSITION:
                        arrowtail = "diamond";
                        break;
                    case ObjectLinkType.DEPENDENCY:
                        style = "dashed";
                        break;
                    default:
                        break;
                }

                if (link.label != null && link.label.length > 0) {
                    sb.append("  %s -> %s [label=\"%s\", style=%s, arrowhead=%s, arrowtail=%s, dir=both];\n".printf(
                        from_id, to_id, escape_label(link.label), style, arrowhead, arrowtail));
                } else {
                    sb.append("  %s -> %s [style=%s, arrowhead=%s, arrowtail=%s, dir=both];\n".printf(
                        from_id, to_id, style, arrowhead, arrowtail));
                }
            }

            sb.append("}\n");

            return sb.str;
        }

        public uint8[]? render_object_to_svg(ObjectDiagram diagram) {
            string dot = generate_object_dot(diagram);

            try {
                string tmp_dot = "/tmp/gplantuml_object.dot";
                string tmp_svg = "/tmp/gplantuml_object.svg";

                FileUtils.set_contents(tmp_dot, dot);

                string[] argv = {layout_engine, "-Tsvg", "-o", tmp_svg, tmp_dot};
                int exit_status;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);

                if (exit_status != 0) {
                    warning("Graphviz returned error %d", exit_status);
                    return null;
                }

                string svg_content;
                FileUtils.get_contents(tmp_svg, out svg_content);

                return svg_content.data;
            } catch (Error e) {
                warning("Failed to render object diagram: %s", e.message);
                return null;
            }
        }

        public Cairo.ImageSurface? render_object_to_surface(ObjectDiagram diagram) {
            uint8[]? svg_data = render_object_to_svg(diagram);
            if (svg_data == null) {
                return null;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, (int)width, (int)height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                // Build element lines map for click-to-source
                var element_lines = new Gee.HashMap<string, int>();
                foreach (var obj in diagram.objects) {
                    if (obj.source_line > 0) {
                        element_lines.set(obj.name, obj.source_line);
                        element_lines.set(obj.get_id(), obj.source_line);
                    }
                }
                foreach (var note in diagram.notes) {
                    if (note.source_line > 0) {
                        element_lines.set(note.id, note.source_line);
                    }
                }
                parse_svg_regions(svg_data, element_lines, (int)width, (int)height);

                return surface;
            } catch (Error e) {
                warning("Failed to create surface from SVG: %s", e.message);
                return null;
            }
        }

        public bool export_object_to_png(ObjectDiagram diagram, string filename) {
            var surface = render_object_to_surface(diagram);
            if (surface == null) {
                return false;
            }

            var status = surface.write_to_png(filename);
            return status == Cairo.Status.SUCCESS;
        }

        public bool export_object_to_svg(ObjectDiagram diagram, string filename) {
            uint8[]? svg_data = render_object_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                FileUtils.set_contents(filename, (string)svg_data);
                return true;
            } catch (Error e) {
                warning("Failed to write SVG: %s", e.message);
                return false;
            }
        }

        public bool export_object_to_pdf(ObjectDiagram diagram, string filename) {
            uint8[]? svg_data = render_object_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                var surface = new Cairo.PdfSurface(filename, width, height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                surface.finish();

                return surface.status() == Cairo.Status.SUCCESS;
            } catch (Error e) {
                warning("Failed to export PDF: %s", e.message);
                return false;
            }
        }

        // ==================== Deployment Diagram Rendering ====================

        private string get_deployment_node_shape(DeploymentNodeType node_type) {
            switch (node_type) {
                case DeploymentNodeType.NODE:
                    return "box3d";
                case DeploymentNodeType.DEVICE:
                    return "component";
                case DeploymentNodeType.ARTIFACT:
                    return "note";
                case DeploymentNodeType.COMPONENT:
                    return "component";
                case DeploymentNodeType.DATABASE:
                    return "cylinder";
                case DeploymentNodeType.CLOUD:
                    return "ellipse";
                case DeploymentNodeType.RECTANGLE:
                    return "box";
                case DeploymentNodeType.FOLDER:
                    return "folder";
                case DeploymentNodeType.FRAME:
                    return "box";
                case DeploymentNodeType.STORAGE:
                    return "cylinder";
                case DeploymentNodeType.QUEUE:
                    return "cds";
                case DeploymentNodeType.STACK:
                    return "box3d";
                case DeploymentNodeType.FILE:
                    return "note";
                case DeploymentNodeType.CARD:
                    return "box";
                case DeploymentNodeType.AGENT:
                    return "house";
                default:
                    return "box";
            }
        }

        private string get_deployment_node_color(DeploymentNodeType node_type, DeploymentDiagram diagram) {
            switch (node_type) {
                case DeploymentNodeType.NODE:
                    return diagram.skin_params.get_element_property("node", "BackgroundColor") ?? "#FEFECE";
                case DeploymentNodeType.DEVICE:
                    return diagram.skin_params.get_element_property("device", "BackgroundColor") ?? "#E8F4FA";
                case DeploymentNodeType.ARTIFACT:
                    return diagram.skin_params.get_element_property("artifact", "BackgroundColor") ?? "#FFFFCC";
                case DeploymentNodeType.COMPONENT:
                    return diagram.skin_params.get_element_property("component", "BackgroundColor") ?? "#FEFECE";
                case DeploymentNodeType.DATABASE:
                    return diagram.skin_params.get_element_property("database", "BackgroundColor") ?? "#DFF0D8";
                case DeploymentNodeType.CLOUD:
                    return diagram.skin_params.get_element_property("cloud", "BackgroundColor") ?? "#E6F3FF";
                case DeploymentNodeType.FOLDER:
                    return diagram.skin_params.get_element_property("folder", "BackgroundColor") ?? "#FFFACD";
                case DeploymentNodeType.FRAME:
                    return diagram.skin_params.get_element_property("frame", "BackgroundColor") ?? "#F5F5F5";
                case DeploymentNodeType.STORAGE:
                    return diagram.skin_params.get_element_property("storage", "BackgroundColor") ?? "#FFE4E1";
                case DeploymentNodeType.QUEUE:
                    return diagram.skin_params.get_element_property("queue", "BackgroundColor") ?? "#E0FFE0";
                default:
                    return "#FEFECE";
            }
        }

        private void generate_deployment_node_dot(StringBuilder sb, DeploymentNode node, DeploymentDiagram diagram, int indent) {
            string indent_str = string.nfill(indent * 2, ' ');
            string node_id = node.get_dot_id();
            string label = node.get_display_label();

            if (node.is_container && node.children.size > 0) {
                // Create a subgraph (cluster) for container nodes
                sb.append("%ssubgraph cluster_%s {\n".printf(indent_str, node_id));
                sb.append("%s  label=\"%s\";\n".printf(indent_str, escape_label(label)));

                // Add stereotype if present
                if (node.stereotype != null) {
                    sb.append("%s  labelloc=\"t\";\n".printf(indent_str));
                }

                string fill_color = node.color ?? get_deployment_node_color(node.node_type, diagram);
                sb.append("%s  style=filled;\n".printf(indent_str));
                sb.append("%s  fillcolor=\"%s\";\n".printf(indent_str, fill_color));
                sb.append("%s  color=\"#333333\";\n".printf(indent_str));

                // Add children
                foreach (var child in node.children) {
                    generate_deployment_node_dot(sb, child, diagram, indent + 1);
                }

                sb.append("%s}\n".printf(indent_str));
            } else {
                // Regular node
                string shape = get_deployment_node_shape(node.node_type);
                string fill_color = node.color ?? get_deployment_node_color(node.node_type, diagram);

                // Build label with stereotype
                var label_builder = new StringBuilder();
                if (node.stereotype != null) {
                    label_builder.append("<<");
                    label_builder.append(node.stereotype);
                    label_builder.append(">>\\n");
                }
                label_builder.append(escape_label(label));

                sb.append("%s%s [label=\"%s\", shape=%s, style=filled, fillcolor=\"%s\", color=\"#333333\"];\n".printf(
                    indent_str, node_id, label_builder.str, shape, fill_color));
            }
        }

        public string generate_deployment_dot(DeploymentDiagram diagram) {
            var sb = new StringBuilder();
            sb.append("digraph G {\n");
            sb.append("  rankdir=%s;\n".printf(diagram.left_to_right ? "LR" : "TB"));
            sb.append("  compound=true;\n");
            sb.append("  fontname=\"Sans\";\n");
            sb.append("  node [fontname=\"Sans\", fontsize=11];\n");
            sb.append("  edge [fontname=\"Sans\", fontsize=10];\n");

            // Title
            if (diagram.title != null) {
                sb.append("  labelloc=\"t\";\n");
                sb.append("  label=\"%s\";\n".printf(escape_label(diagram.title)));
                sb.append("  fontsize=16;\n");
            }

            // Render nodes
            sb.append("\n  // Nodes\n");
            foreach (var node in diagram.nodes) {
                generate_deployment_node_dot(sb, node, diagram, 1);
            }

            // Render notes
            if (diagram.notes.size > 0) {
                sb.append("\n  // Notes\n");
                string note_color = diagram.skin_params.get_element_property("note", "BackgroundColor") ?? "#FFFFCC";

                foreach (var note in diagram.notes) {
                    sb.append("  %s [label=\"%s\", shape=note, style=filled, fillcolor=\"%s\"];\n".printf(
                        note.id, escape_label(note.text), note_color));

                    if (note.attached_to != null) {
                        var target = diagram.find_node(note.attached_to);
                        if (target != null) {
                            sb.append("  %s -> %s [style=dashed, arrowhead=none];\n".printf(
                                note.id, target.get_dot_id()));
                        }
                    }
                }
            }

            // Render connections
            sb.append("\n  // Connections\n");
            foreach (var conn in diagram.connections) {
                var from = diagram.find_node(conn.from_id);
                var to = diagram.find_node(conn.to_id);

                if (from == null || to == null) continue;

                string from_id = from.get_dot_id();
                string to_id = to.get_dot_id();
                string style = conn.is_dashed ? "dashed" : "solid";
                string arrowhead = "vee";
                string arrowtail = "none";

                switch (conn.connection_type) {
                    case DeploymentConnectionType.ASSOCIATION:
                        arrowhead = "none";
                        break;
                    case DeploymentConnectionType.DEPENDENCY:
                        style = "dashed";
                        break;
                    case DeploymentConnectionType.DIRECTED:
                        arrowhead = "vee";
                        break;
                    case DeploymentConnectionType.BIDIRECTIONAL:
                        arrowhead = "vee";
                        arrowtail = "vee";
                        break;
                }

                // Build label with protocol if present
                var label_builder = new StringBuilder();
                if (conn.label != null && conn.label.length > 0) {
                    label_builder.append(escape_label(conn.label));
                }
                if (conn.protocol != null && conn.protocol.length > 0) {
                    if (label_builder.len > 0) {
                        label_builder.append("\\n");
                    }
                    label_builder.append("<<");
                    label_builder.append(conn.protocol);
                    label_builder.append(">>");
                }

                if (label_builder.len > 0) {
                    sb.append("  %s -> %s [label=\"%s\", style=%s, arrowhead=%s, arrowtail=%s, dir=both];\n".printf(
                        from_id, to_id, label_builder.str, style, arrowhead, arrowtail));
                } else {
                    sb.append("  %s -> %s [style=%s, arrowhead=%s, arrowtail=%s, dir=both];\n".printf(
                        from_id, to_id, style, arrowhead, arrowtail));
                }
            }

            sb.append("}\n");

            return sb.str;
        }

        public uint8[]? render_deployment_to_svg(DeploymentDiagram diagram) {
            string dot = generate_deployment_dot(diagram);

            try {
                string tmp_dot = "/tmp/gplantuml_deployment.dot";
                string tmp_svg = "/tmp/gplantuml_deployment.svg";

                FileUtils.set_contents(tmp_dot, dot);

                string[] argv = {layout_engine, "-Tsvg", "-o", tmp_svg, tmp_dot};
                int exit_status;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);

                if (exit_status != 0) {
                    warning("Graphviz returned error %d", exit_status);
                    return null;
                }

                string svg_content;
                FileUtils.get_contents(tmp_svg, out svg_content);

                return svg_content.data;
            } catch (Error e) {
                warning("Failed to render deployment diagram: %s", e.message);
                return null;
            }
        }

        public Cairo.ImageSurface? render_deployment_to_surface(DeploymentDiagram diagram) {
            uint8[]? svg_data = render_deployment_to_svg(diagram);
            if (svg_data == null) {
                return null;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, (int)width, (int)height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                // Build element lines map for click-to-source
                var element_lines = new Gee.HashMap<string, int>();
                add_deployment_node_lines(diagram.nodes, element_lines);
                foreach (var note in diagram.notes) {
                    if (note.source_line > 0) {
                        element_lines.set(note.id, note.source_line);
                    }
                }
                parse_svg_regions(svg_data, element_lines, (int)width, (int)height);

                return surface;
            } catch (Error e) {
                warning("Failed to create surface from SVG: %s", e.message);
                return null;
            }
        }

        private void add_deployment_node_lines(Gee.ArrayList<DeploymentNode> nodes, Gee.HashMap<string, int> element_lines) {
            foreach (var node in nodes) {
                if (node.source_line > 0) {
                    element_lines.set(node.id, node.source_line);
                    element_lines.set(node.get_dot_id(), node.source_line);
                    if (node.alias != null) {
                        element_lines.set(node.alias, node.source_line);
                    }
                }
                // Recursively add children
                add_deployment_node_lines(node.children, element_lines);
            }
        }

        public bool export_deployment_to_png(DeploymentDiagram diagram, string filename) {
            var surface = render_deployment_to_surface(diagram);
            if (surface == null) {
                return false;
            }

            var status = surface.write_to_png(filename);
            return status == Cairo.Status.SUCCESS;
        }

        public bool export_deployment_to_svg(DeploymentDiagram diagram, string filename) {
            uint8[]? svg_data = render_deployment_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                FileUtils.set_contents(filename, (string)svg_data);
                return true;
            } catch (Error e) {
                warning("Failed to write SVG: %s", e.message);
                return false;
            }
        }

        public bool export_deployment_to_pdf(DeploymentDiagram diagram, string filename) {
            uint8[]? svg_data = render_deployment_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                var surface = new Cairo.PdfSurface(filename, width, height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                surface.finish();

                return surface.status() == Cairo.Status.SUCCESS;
            } catch (Error e) {
                warning("Failed to export PDF: %s", e.message);
                return false;
            }
        }

        // ==================== ER Diagram Rendering ====================

        public string generate_er_dot(ERDiagram diagram) {
            var sb = new StringBuilder();
            sb.append("digraph G {\n");
            sb.append("  rankdir=%s;\n".printf(diagram.left_to_right ? "LR" : "TB"));
            sb.append("  fontname=\"Sans\";\n");
            sb.append("  node [fontname=\"Sans\", fontsize=11, shape=record];\n");
            sb.append("  edge [fontname=\"Sans\", fontsize=10];\n");

            // Title
            if (diagram.title != null) {
                sb.append("  labelloc=\"t\";\n");
                sb.append("  label=\"%s\";\n".printf(escape_label(diagram.title)));
                sb.append("  fontsize=16;\n");
            }

            // Render entities
            sb.append("\n  // Entities\n");
            string entity_fill = diagram.skin_params.get_element_property("entity", "BackgroundColor") ?? "#FEFECE";
            string entity_border = diagram.skin_params.get_element_property("entity", "BorderColor") ?? "#A80036";

            foreach (var entity in diagram.entities) {
                string id = entity.get_dot_id();
                string fill = entity.color ?? entity_fill;

                // Build record label
                var label_parts = new StringBuilder();
                label_parts.append("{");
                label_parts.append(escape_label(entity.get_display_name()));

                if (entity.attributes.size > 0) {
                    label_parts.append("|");

                    bool first = true;
                    bool in_separator = false;

                    foreach (var attr in entity.attributes) {
                        if (!first && !in_separator) {
                            label_parts.append("\\l");
                        }
                        first = false;
                        in_separator = false;

                        label_parts.append(escape_label(attr.get_display_text()));
                    }

                    if (!first) {
                        label_parts.append("\\l");
                    }
                }

                label_parts.append("}");

                sb.append("  %s [label=\"%s\", style=filled, fillcolor=\"%s\", color=\"%s\"];\n".printf(
                    id, label_parts.str, fill, entity_border));
            }

            // Render notes
            if (diagram.notes.size > 0) {
                sb.append("\n  // Notes\n");
                string note_color = diagram.skin_params.get_element_property("note", "BackgroundColor") ?? "#FFFFCC";

                foreach (var note in diagram.notes) {
                    sb.append("  %s [label=\"%s\", shape=note, style=filled, fillcolor=\"%s\"];\n".printf(
                        note.id, escape_label(note.text), note_color));

                    if (note.attached_to != null) {
                        var target = diagram.find_entity(note.attached_to);
                        if (target != null) {
                            sb.append("  %s -> %s [style=dashed, arrowhead=none];\n".printf(
                                note.id, target.get_dot_id()));
                        }
                    }
                }
            }

            // Render relationships
            sb.append("\n  // Relationships\n");
            foreach (var rel in diagram.relationships) {
                var from = diagram.find_entity(rel.from_entity);
                var to = diagram.find_entity(rel.to_entity);

                if (from == null || to == null) continue;

                string from_id = from.get_dot_id();
                string to_id = to.get_dot_id();
                string style = rel.is_dashed ? "dashed" : "solid";

                // Cardinality decorations
                string arrowtail = get_er_cardinality_arrow(rel.from_cardinality);
                string arrowhead = get_er_cardinality_arrow(rel.to_cardinality);

                if (rel.label != null && rel.label.length > 0) {
                    sb.append("  %s -> %s [label=\"%s\", style=%s, arrowhead=%s, arrowtail=%s, dir=both];\n".printf(
                        from_id, to_id, escape_label(rel.label), style, arrowhead, arrowtail));
                } else {
                    sb.append("  %s -> %s [style=%s, arrowhead=%s, arrowtail=%s, dir=both];\n".printf(
                        from_id, to_id, style, arrowhead, arrowtail));
                }
            }

            sb.append("}\n");

            return sb.str;
        }

        private string get_er_cardinality_arrow(ERCardinality card) {
            switch (card) {
                case ERCardinality.ONE_TO_ONE:
                    return "tee";
                case ERCardinality.ONE_TO_MANY:
                    return "crowodot";
                case ERCardinality.MANY_TO_ONE:
                    return "crowodot";
                case ERCardinality.MANY_TO_MANY:
                    return "crowodot";
                case ERCardinality.ZERO_OR_ONE:
                    return "teeodot";
                case ERCardinality.ZERO_OR_MANY:
                    return "crowodot";
                case ERCardinality.ONE_MANDATORY:
                    return "tee";
                case ERCardinality.MANY_MANDATORY:
                    return "crow";
                default:
                    return "none";
            }
        }

        public uint8[]? render_er_to_svg(ERDiagram diagram) {
            string dot = generate_er_dot(diagram);

            try {
                string tmp_dot = "/tmp/gplantuml_er.dot";
                string tmp_svg = "/tmp/gplantuml_er.svg";

                FileUtils.set_contents(tmp_dot, dot);

                string[] argv = {layout_engine, "-Tsvg", "-o", tmp_svg, tmp_dot};
                int exit_status;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);

                if (exit_status != 0) {
                    warning("Graphviz returned error %d", exit_status);
                    return null;
                }

                string svg_content;
                FileUtils.get_contents(tmp_svg, out svg_content);

                return svg_content.data;
            } catch (Error e) {
                warning("Failed to render ER diagram: %s", e.message);
                return null;
            }
        }

        public Cairo.ImageSurface? render_er_to_surface(ERDiagram diagram) {
            uint8[]? svg_data = render_er_to_svg(diagram);
            if (svg_data == null) {
                return null;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, (int)width, (int)height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                // Build element lines map for click-to-source
                var element_lines = new Gee.HashMap<string, int>();
                foreach (var entity in diagram.entities) {
                    if (entity.source_line > 0) {
                        element_lines.set(entity.name, entity.source_line);
                        element_lines.set(entity.get_dot_id(), entity.source_line);
                        if (entity.alias != null) {
                            element_lines.set(entity.alias, entity.source_line);
                        }
                    }
                }
                foreach (var note in diagram.notes) {
                    if (note.source_line > 0) {
                        element_lines.set(note.id, note.source_line);
                    }
                }
                parse_svg_regions(svg_data, element_lines, (int)width, (int)height);

                return surface;
            } catch (Error e) {
                warning("Failed to create surface from SVG: %s", e.message);
                return null;
            }
        }

        public bool export_er_to_png(ERDiagram diagram, string filename) {
            var surface = render_er_to_surface(diagram);
            if (surface == null) {
                return false;
            }

            var status = surface.write_to_png(filename);
            return status == Cairo.Status.SUCCESS;
        }

        public bool export_er_to_svg(ERDiagram diagram, string filename) {
            uint8[]? svg_data = render_er_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                FileUtils.set_contents(filename, (string)svg_data);
                return true;
            } catch (Error e) {
                warning("Failed to write SVG: %s", e.message);
                return false;
            }
        }

        public bool export_er_to_pdf(ERDiagram diagram, string filename) {
            uint8[]? svg_data = render_er_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                var surface = new Cairo.PdfSurface(filename, width, height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                surface.finish();

                return surface.status() == Cairo.Status.SUCCESS;
            } catch (Error e) {
                warning("Failed to export PDF: %s", e.message);
                return false;
            }
        }

        // ==================== MindMap / WBS Diagram Rendering ====================

        private string get_mindmap_node_shape(MindMapNodeStyle style, bool is_wbs) {
            if (is_wbs) {
                // WBS always uses boxes
                return "box";
            }

            switch (style) {
                case MindMapNodeStyle.BOX:
                    return "box";
                case MindMapNodeStyle.ROUNDED:
                    return "box";  // Will add rounded corners
                case MindMapNodeStyle.CLOUD:
                    return "ellipse";
                case MindMapNodeStyle.PILL:
                    return "ellipse";
                default:
                    return "box";
            }
        }

        private void generate_mindmap_node_dot(StringBuilder sb, MindMapNode node, MindMapDiagram diagram, bool is_wbs) {
            string id = node.get_dot_id();
            string shape = get_mindmap_node_shape(node.style, is_wbs);
            string text = escape_label(node.text);

            // Color based on level
            string[] level_colors = { "#FEFECE", "#E6F3FF", "#DFF0D8", "#FCF8E3", "#F2DEDE", "#D9EDF7" };
            string fill_color = node.color ?? level_colors[node.level % level_colors.length];

            string style = "filled";
            if (node.style == MindMapNodeStyle.ROUNDED || node.style == MindMapNodeStyle.PILL) {
                style = "filled,rounded";
            }

            sb.append("  %s [label=\"%s\", shape=%s, style=\"%s\", fillcolor=\"%s\", color=\"#333333\"];\n".printf(
                id, text, shape, style, fill_color));

            // Connect to children
            foreach (var child in node.children) {
                generate_mindmap_node_dot(sb, child, diagram, is_wbs);
                sb.append("  %s -> %s [arrowhead=none];\n".printf(id, child.get_dot_id()));
            }
        }

        public string generate_mindmap_dot(MindMapDiagram diagram) {
            var sb = new StringBuilder();
            bool is_wbs = diagram.diagram_type == DiagramType.WBS;

            sb.append("digraph G {\n");
            sb.append("  rankdir=LR;\n");  // Left to right for mindmaps
            sb.append("  fontname=\"Sans\";\n");
            sb.append("  node [fontname=\"Sans\", fontsize=11];\n");
            sb.append("  edge [fontname=\"Sans\", fontsize=10];\n");
            sb.append("  nodesep=0.3;\n");
            sb.append("  ranksep=0.5;\n");

            // Title
            if (diagram.title != null) {
                sb.append("  labelloc=\"t\";\n");
                sb.append("  label=\"%s\";\n".printf(escape_label(diagram.title)));
                sb.append("  fontsize=16;\n");
            }

            // Render tree from root
            sb.append("\n  // Nodes\n");
            if (diagram.root != null) {
                generate_mindmap_node_dot(sb, diagram.root, diagram, is_wbs);
            }

            sb.append("}\n");

            return sb.str;
        }

        public uint8[]? render_mindmap_to_svg(MindMapDiagram diagram) {
            string dot = generate_mindmap_dot(diagram);

            try {
                string tmp_dot = "/tmp/gplantuml_mindmap.dot";
                string tmp_svg = "/tmp/gplantuml_mindmap.svg";

                FileUtils.set_contents(tmp_dot, dot);

                string[] argv = {layout_engine, "-Tsvg", "-o", tmp_svg, tmp_dot};
                int exit_status;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out exit_status);

                if (exit_status != 0) {
                    warning("Graphviz returned error %d", exit_status);
                    return null;
                }

                string svg_content;
                FileUtils.get_contents(tmp_svg, out svg_content);

                return svg_content.data;
            } catch (Error e) {
                warning("Failed to render MindMap diagram: %s", e.message);
                return null;
            }
        }

        public Cairo.ImageSurface? render_mindmap_to_surface(MindMapDiagram diagram) {
            uint8[]? svg_data = render_mindmap_to_svg(diagram);
            if (svg_data == null) {
                return null;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, (int)width, (int)height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                // Build element lines map for click-to-source
                var element_lines = new Gee.HashMap<string, int>();
                var all_nodes = diagram.get_all_nodes();
                foreach (var node in all_nodes) {
                    if (node.source_line > 0) {
                        element_lines.set(node.get_dot_id(), node.source_line);
                    }
                }
                parse_svg_regions(svg_data, element_lines, (int)width, (int)height);

                return surface;
            } catch (Error e) {
                warning("Failed to create surface from SVG: %s", e.message);
                return null;
            }
        }

        public bool export_mindmap_to_png(MindMapDiagram diagram, string filename) {
            var surface = render_mindmap_to_surface(diagram);
            if (surface == null) {
                return false;
            }

            var status = surface.write_to_png(filename);
            return status == Cairo.Status.SUCCESS;
        }

        public bool export_mindmap_to_svg(MindMapDiagram diagram, string filename) {
            uint8[]? svg_data = render_mindmap_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                FileUtils.set_contents(filename, (string)svg_data);
                return true;
            } catch (Error e) {
                warning("Failed to write SVG: %s", e.message);
                return false;
            }
        }

        public bool export_mindmap_to_pdf(MindMapDiagram diagram, string filename) {
            uint8[]? svg_data = render_mindmap_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                var surface = new Cairo.PdfSurface(filename, width, height);
                var cr = new Cairo.Context(surface);

                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                surface.finish();

                return surface.status() == Cairo.Status.SUCCESS;
            } catch (Error e) {
                warning("Failed to export PDF: %s", e.message);
                return false;
            }
        }

        // ==================== Sequence Diagram Rendering ====================

        public uint8[]? render_to_svg(SequenceDiagram diagram) {
            string dot = generate_dot(diagram);

            // Parse DOT into graph
            var graph = Gvc.Graph.read_string(dot);
            if (graph == null) {
                warning("Failed to parse DOT graph");
                return null;
            }

            // Layout
            int ret = context.layout(graph, layout_engine);
            if (ret != 0) {
                warning("Failed to layout graph with engine: %s", layout_engine);
                return null;
            }

            // Render to SVG
            uint8[] svg_data;
            ret = context.render_data(graph, "svg", out svg_data);

            context.free_layout(graph);

            if (ret != 0) {
                warning("Failed to render graph");
                return null;
            }

            return svg_data;
        }

        public Cairo.ImageSurface? render_to_surface(SequenceDiagram diagram) {
            uint8[]? svg_data = render_to_svg(diagram);
            if (svg_data == null) {
                return null;
            }

            try {
                // Load SVG with librsvg
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                // Build element line number map from participants
                var element_lines = new Gee.HashMap<string, int>();
                foreach (var participant in diagram.participants) {
                    if (participant.source_line > 0) {
                        element_lines.set(participant.name, participant.source_line);
                        if (participant.alias != null) {
                            element_lines.set(participant.alias, participant.source_line);
                        }
                    }
                }

                // Parse SVG regions for click-to-source navigation (with pixel scaling)
                parse_svg_regions(svg_data, element_lines, width, height);

                // Create Cairo surface
                var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, (int)width, (int)height);
                var cr = new Cairo.Context(surface);

                // White background
                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                // Render SVG
                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                return surface;
            } catch (Error e) {
                warning("Failed to render SVG: %s", e.message);
                return null;
            }
        }

        public bool export_to_png(SequenceDiagram diagram, string filename) {
            var surface = render_to_surface(diagram);
            if (surface == null) {
                return false;
            }

            var status = surface.write_to_png(filename);
            return status == Cairo.Status.SUCCESS;
        }

        public bool export_to_svg(SequenceDiagram diagram, string filename) {
            uint8[]? svg_data = render_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                var file = File.new_for_path(filename);
                var stream = file.replace(null, false, FileCreateFlags.NONE);
                stream.write_all(svg_data, null);
                stream.close();
                return true;
            } catch (Error e) {
                warning("Failed to write SVG: %s", e.message);
                return false;
            }
        }

        public bool export_to_pdf(SequenceDiagram diagram, string filename) {
            uint8[]? svg_data = render_to_svg(diagram);
            if (svg_data == null) {
                return false;
            }

            try {
                // Load SVG
                var stream = new MemoryInputStream.from_data(svg_data);
                var handle = new Rsvg.Handle.from_stream_sync(stream, null, Rsvg.HandleFlags.FLAGS_NONE, null);

                double width, height;
                handle.get_intrinsic_size_in_pixels(out width, out height);

                if (width <= 0) width = 400;
                if (height <= 0) height = 300;

                // Create PDF surface
                var surface = new Cairo.PdfSurface(filename, width, height);
                var cr = new Cairo.Context(surface);

                // White background
                cr.set_source_rgb(1, 1, 1);
                cr.paint();

                // Render SVG to PDF
                var viewport = Rsvg.Rectangle() {
                    x = 0,
                    y = 0,
                    width = width,
                    height = height
                };
                handle.render_document(cr, viewport);

                // Finish the PDF
                surface.finish();

                return surface.status() == Cairo.Status.SUCCESS;
            } catch (Error e) {
                warning("Failed to export PDF: %s", e.message);
                return false;
            }
        }

        // Parse SVG to extract element bounding boxes for click navigation
        // surface_width/height are optional - if provided, coordinates will be scaled from SVG units to pixels
        public void parse_svg_regions(uint8[] svg_data, Gee.HashMap<string, int>? element_lines = null,
                                       double surface_width = 0, double surface_height = 0) {
            last_regions.clear();

            string svg_str = (string)svg_data;

            try {
                // Extract SVG viewBox or width/height to determine coordinate scaling
                double svg_width = 0, svg_height = 0;
                var viewbox_regex = new Regex("viewBox=\"([\\d.]+)\\s+([\\d.]+)\\s+([\\d.]+)\\s+([\\d.]+)\"");
                MatchInfo viewbox_match;
                if (viewbox_regex.match(svg_str, 0, out viewbox_match)) {
                    svg_width = double.parse(viewbox_match.fetch(3));
                    svg_height = double.parse(viewbox_match.fetch(4));
                }

                // Calculate scale factor (pt to pixels)
                double scale_x = 1.0, scale_y = 1.0;
                if (surface_width > 0 && svg_width > 0) {
                    scale_x = surface_width / svg_width;
                }
                if (surface_height > 0 && svg_height > 0) {
                    scale_y = surface_height / svg_height;
                }

                // Extract the root graph transform (Graphviz uses translate to flip Y-axis)
                double translate_x = 0, translate_y = 0;
                var transform_regex = new Regex("<g[^>]*class=\"graph\"[^>]*transform=\"[^\"]*translate\\(([\\d.]+)\\s+([\\d.]+)\\)");
                MatchInfo transform_match;
                if (transform_regex.match(svg_str, 0, out transform_match)) {
                    translate_x = double.parse(transform_match.fetch(1));
                    translate_y = double.parse(transform_match.fetch(2));
                }

                // Parse all <g> groups that have a <title> element (Graphviz convention)
                // Only match nodes (class="node"), not clusters or edges
                var group_regex = new Regex(
                    "<g[^>]*class=\"node\"[^>]*>\\s*<title>([^<]+)</title>(.*?)</g>",
                    RegexCompileFlags.DOTALL
                );

                MatchInfo match;
                if (group_regex.match(svg_str, 0, out match)) {
                    do {
                        string title = match.fetch(1);
                        string content = match.fetch(2);

                        if (title == null || title.length == 0 || title == "G") {
                            continue; // Skip the root graph
                        }

                        // Skip edges (title contains "->")
                        if (title.contains("->") || title.contains("&#45;&gt;")) {
                            continue;
                        }

                        double min_x = double.MAX, min_y = double.MAX;
                        double max_x = -double.MAX, max_y = -double.MAX;

                        // Try to extract bounding box from various SVG shapes

                        // 1. Polygon points
                        var poly_regex = new Regex("points=\"([^\"]+)\"");
                        MatchInfo poly_match;
                        if (poly_regex.match(content, 0, out poly_match)) {
                            string points = poly_match.fetch(1);
                            parse_polygon_bounds(points, ref min_x, ref min_y, ref max_x, ref max_y);
                        }

                        // 2. Ellipse
                        var ellipse_regex = new Regex("cx=\"([^\"]+)\"[^>]*cy=\"([^\"]+)\"[^>]*rx=\"([^\"]+)\"[^>]*ry=\"([^\"]+)\"");
                        MatchInfo ellipse_match;
                        if (ellipse_regex.match(content, 0, out ellipse_match)) {
                            double cx = double.parse(ellipse_match.fetch(1));
                            double cy = double.parse(ellipse_match.fetch(2));
                            double rx = double.parse(ellipse_match.fetch(3));
                            double ry = double.parse(ellipse_match.fetch(4));
                            min_x = double.min(min_x, cx - rx);
                            max_x = double.max(max_x, cx + rx);
                            min_y = double.min(min_y, cy - ry);
                            max_y = double.max(max_y, cy + ry);
                        }

                        // 3. Rectangle
                        var rect_regex = new Regex("<rect[^>]*x=\"([^\"]+)\"[^>]*y=\"([^\"]+)\"[^>]*width=\"([^\"]+)\"[^>]*height=\"([^\"]+)\"");
                        MatchInfo rect_match;
                        if (rect_regex.match(content, 0, out rect_match)) {
                            double x = double.parse(rect_match.fetch(1));
                            double y = double.parse(rect_match.fetch(2));
                            double w = double.parse(rect_match.fetch(3));
                            double h = double.parse(rect_match.fetch(4));
                            min_x = double.min(min_x, x);
                            max_x = double.max(max_x, x + w);
                            min_y = double.min(min_y, y);
                            max_y = double.max(max_y, y + h);
                        }

                        // 4. Path - extract from 'd' attribute (basic bounding box)
                        var path_regex = new Regex("<path[^>]*d=\"([^\"]+)\"");
                        MatchInfo path_match;
                        if (path_regex.match(content, 0, out path_match)) {
                            string d = path_match.fetch(1);
                            parse_path_bounds(d, ref min_x, ref min_y, ref max_x, ref max_y);
                        }

                        // 5. Text position as fallback (only if no shape bounds found)
                        if (min_x >= double.MAX || max_x <= double.MIN) {
                            var text_regex = new Regex("<text[^>]*x=\"([^\"]+)\"[^>]*y=\"([^\"]+)\"");
                            MatchInfo text_match;
                            if (text_regex.match(content, 0, out text_match)) {
                                double tx = double.parse(text_match.fetch(1));
                                double ty = double.parse(text_match.fetch(2));
                                // Approximate text bounds
                                min_x = double.min(min_x, tx - 50);
                                max_x = double.max(max_x, tx + 50);
                                min_y = double.min(min_y, ty - 15);
                                max_y = double.max(max_y, ty + 5);
                            }
                        }

                        if (min_x < double.MAX && max_x > -double.MAX) {
                            int line = 0;
                            if (element_lines != null && element_lines.has_key(title)) {
                                line = element_lines.get(title);
                            }
                            // Apply the graph transform (translate_x, translate_y)
                            // Graphviz uses inverted Y-axis, so we add the translate values
                            // Then scale to pixel coordinates
                            double final_x = (translate_x + min_x) * scale_x;
                            double final_y = (translate_y + min_y) * scale_y;
                            double final_width = (max_x - min_x) * scale_x;
                            double final_height = (max_y - min_y) * scale_y;

                            last_regions.add(new ElementRegion(
                                title, line,
                                final_x, final_y,
                                final_width, final_height
                            ));
                        }
                    } while (match.next());
                }
            } catch (Error e) {
                warning("Failed to parse SVG regions: %s", e.message);
            }
        }

        private void parse_polygon_bounds(string points, ref double min_x, ref double min_y,
                                          ref double max_x, ref double max_y) {
            string[] point_pairs = points.split(" ");
            foreach (var pair in point_pairs) {
                string[] coords = pair.split(",");
                if (coords.length >= 2) {
                    double x = double.parse(coords[0]);
                    double y = double.parse(coords[1]);
                    min_x = double.min(min_x, x);
                    min_y = double.min(min_y, y);
                    max_x = double.max(max_x, x);
                    max_y = double.max(max_y, y);
                }
            }
        }

        private void parse_path_bounds(string d, ref double min_x, ref double min_y,
                                       ref double max_x, ref double max_y) {
            // Simple path parsing - extract numeric coordinates
            try {
                var num_regex = new Regex("(-?[0-9]+\\.?[0-9]*)");
                MatchInfo match;
                var numbers = new Gee.ArrayList<double?>();

                if (num_regex.match(d, 0, out match)) {
                    do {
                        numbers.add(double.parse(match.fetch(1)));
                    } while (match.next());
                }

                // Assume alternating x,y pairs
                for (int i = 0; i < numbers.size - 1; i += 2) {
                    double x = numbers[i];
                    double y = numbers[i + 1];
                    min_x = double.min(min_x, x);
                    min_y = double.min(min_y, y);
                    max_x = double.max(max_x, x);
                    max_y = double.max(max_y, y);
                }
            } catch (Error e) {
                // Ignore path parsing errors
            }
        }
    }
}
