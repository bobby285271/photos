/*
* Copyright (c) 2009-2013 Yorba Foundation
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU Lesser General Public
* License as published by the Free Software Foundation; either
* version 2.1 of the License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU General Public
* License along with this program; if not, write to the
* Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
* Boston, MA 02110-1301 USA
*/

extern Soup.Message soup_form_request_new_from_multipart (string uri, Soup.Multipart multipart);

namespace Publishing.RESTSupport {

public abstract class Session {
    private string? endpoint_url = null;
    private Soup.Session soup_session = null;
    private bool transactions_stopped = false;

    public signal void wire_message_unqueued (Soup.Message message);
    public signal void authenticated ();
    public signal void authentication_failed (Spit.Publishing.PublishingError err);

    protected Session (string? endpoint_url = null) {
        this.endpoint_url = endpoint_url;
        soup_session = new Soup.Session ();
    }

    protected void notify_wire_message_unqueued (Soup.Message message) {
        wire_message_unqueued (message);
    }

    protected void notify_authenticated () {
        authenticated ();
    }

    protected void notify_authentication_failed (Spit.Publishing.PublishingError err) {
        authentication_failed (err);
    }

    public abstract bool is_authenticated ();

    public string? get_endpoint_url () {
        return endpoint_url;
    }

    public void stop_transactions () {
        transactions_stopped = true;
        soup_session.abort ();
    }

    public bool are_transactions_stopped () {
        return transactions_stopped;
    }

    public void send_wire_message (Soup.Message message) {
        if (are_transactions_stopped ())
            return;

        soup_session.request_unqueued.connect (notify_wire_message_unqueued);
        soup_session.send_message (message);

        soup_session.request_unqueued.disconnect (notify_wire_message_unqueued);
    }
}

public enum HttpMethod {
    GET,
    POST,
    PUT;

    public string to_string () {
        switch (this) {
        case HttpMethod.GET:
            return "GET";

        case HttpMethod.PUT:
            return "PUT";

        case HttpMethod.POST:
            return "POST";

        default:
            error ("unrecognized HTTP method enumeration value");
        }
    }

    public static HttpMethod from_string (string str) {
        if (str == "GET") {
            return HttpMethod.GET;
        } else if (str == "PUT") {
            return HttpMethod.PUT;
        } else if (str == "POST") {
            return HttpMethod.POST;
        } else {
            error ("unrecognized HTTP method name: %s", str);
        }
    }
}

public class Argument {
    public string key;
    public string value;

    public Argument (string key, string value) {
        this.key = key;
        this.value = value;
    }

    public static int compare (Argument arg1, Argument arg2) {
        return strcmp (arg1.key, arg2.key);
    }

    public static Argument[] sort (Argument[] input_array) {
        FixedTreeSet<Argument> sorted_args = new FixedTreeSet<Argument> (Argument.compare);

        foreach (Argument arg in input_array)
            sorted_args.add (arg);

        return sorted_args.to_array ();
    }
}

public class Transaction {
    private Argument[] arguments;
    private bool is_executed = false;
    private weak Session parent_session = null;
    private Soup.Message message = null;
    private int bytes_written = 0;
    private Spit.Publishing.PublishingError? err = null;
    private string? endpoint_url = null;
    private bool use_custom_payload;

    public signal void chunk_transmitted (int bytes_written_so_far, int total_bytes);
    public signal void network_error (Spit.Publishing.PublishingError err);
    public signal void completed ();

    public Transaction (Session parent_session, HttpMethod method = HttpMethod.POST) {
        // if our creator doesn't specify an endpoint url by using the Transaction.with_endpoint_url
        // constructor, then our parent session must have a non-null endpoint url
        assert (parent_session.get_endpoint_url () != null);

        this.parent_session = parent_session;

        message = new Soup.Message (method.to_string (), parent_session.get_endpoint_url ());
        message.wrote_body_data.connect (on_wrote_body_data);
    }

    public Transaction.with_endpoint_url (Session parent_session, string endpoint_url,
                                          HttpMethod method = HttpMethod.POST) {
        this.parent_session = parent_session;
        this.endpoint_url = endpoint_url;
        message = new Soup.Message (method.to_string (), endpoint_url);
    }

    private void on_wrote_body_data (Soup.Buffer written_data) {
        bytes_written += (int) written_data.length;
        chunk_transmitted (bytes_written, (int) message.request_body.length);
    }

    private void on_message_unqueued (Soup.Message message) {
        if (this.message != message)
            return;

        try {
            check_response (message);
        } catch (Spit.Publishing.PublishingError err) {
            warning ("Publishing error: %s", err.message);
            warning ("response validation failed. bad response = '%s'.", get_response ());
            this.err = err;
        }
    }

    protected void check_response (Soup.Message message) throws Spit.Publishing.PublishingError {
        switch (message.status_code) {
        case Soup.Status.OK:
        case Soup.Status.CREATED: // HTTP code 201 (CREATED) signals that a new
            // resource was created in response to a PUT or POST
            break;

        case Soup.Status.CANT_RESOLVE:
        case Soup.Status.CANT_RESOLVE_PROXY:
            throw new Spit.Publishing.PublishingError.NO_ANSWER ("Unable to resolve %s (error code %u)",
            get_endpoint_url (), message.status_code);

        case Soup.Status.CANT_CONNECT:
        case Soup.Status.CANT_CONNECT_PROXY:
            throw new Spit.Publishing.PublishingError.NO_ANSWER ("Unable to connect to %s (error code %u)",
            get_endpoint_url (), message.status_code);

        default:
            // status codes below 100 are used by Soup, 100 and above are defined HTTP codes
            if (message.status_code >= 100) {
                throw new Spit.Publishing.PublishingError.NO_ANSWER ("Service %s returned HTTP status code %u %s",
                get_endpoint_url (), message.status_code, message.reason_phrase);
            } else {
                throw new Spit.Publishing.PublishingError.NO_ANSWER ("Failure communicating with %s (error code %u)",
                        get_endpoint_url (), message.status_code);
            }
        }

        // All valid communication involves body data in the response
        if (message.response_body.data == null || message.response_body.data.length == 0)
            throw new Spit.Publishing.PublishingError.MALFORMED_RESPONSE ("No response data from %s",
                    get_endpoint_url ());
    }

    public Argument[] get_arguments () {
        return arguments;
    }

    public Argument[] get_sorted_arguments () {
        return Argument.sort (get_arguments ());
    }

    protected void set_is_executed (bool is_executed) {
        this.is_executed = is_executed;
    }

    protected void send () throws Spit.Publishing.PublishingError {
        parent_session.wire_message_unqueued.connect (on_message_unqueued);
        message.wrote_body_data.connect (on_wrote_body_data);
        parent_session.send_wire_message (message);

        parent_session.wire_message_unqueued.disconnect (on_message_unqueued);
        message.wrote_body_data.disconnect (on_wrote_body_data);

        if (err != null)
            network_error (err);
        else
            completed ();

        if (err != null)
            throw err;
    }

    public HttpMethod get_method () {
        return HttpMethod.from_string (message.method);
    }

    protected virtual void add_header (string key, string value) {
        message.request_headers.append (key, value);
    }

    // set custom_payload to null to have this transaction send the default payload of
    // key-value pairs appended through add_argument(...) (this is how most REST requests work).
    // To send a payload other than traditional key-value pairs (such as an XML document or a JPEG
    // image) to the endpoint, set the custom_payload parameter to a non-null value. If the
    // custom_payload you specify is text data, then it's null terminated, and its length is just
    // custom_payload.length, so you don't have to pass in a payload_length parameter in this case.
    // If, however, custom_payload is binary data (such as a JEPG), then the caller must set
    // payload_length to the byte length of the custom_payload buffer
    protected void set_custom_payload (string? custom_payload, string payload_content_type,
                                       ulong payload_length = 0) {
        assert (get_method () != HttpMethod.GET); // GET messages don't have payloads

        if (custom_payload == null) {
            use_custom_payload = false;
            return;
        }

        ulong length = (payload_length > 0) ? payload_length : custom_payload.length;
        message.set_request (payload_content_type, Soup.MemoryUse.COPY, custom_payload.data[0:length]);

        use_custom_payload = true;
    }

    // When writing a specialized transaction subclass you should rarely need to
    // call this method. In general, it's better to leave the underlying Soup message
    // alone and let the Transaction class manage it for you. You should only need
    // to install a new message if your subclass has radically different behavior from
    // normal Transactions -- like multipart encoding.
    protected void set_message (Soup.Message message) {
        this.message = message;
    }

    public bool get_is_executed () {
        return is_executed;
    }

    public uint get_status_code () {
        assert (get_is_executed ());
        return message.status_code;
    }

    public virtual void execute () throws Spit.Publishing.PublishingError {
        // if a custom payload is being used, we don't need to peform the tasks that are necessary
        // to prepare a traditional key-value pair REST request; Instead (since we don't
        // know anything about the custom payload), we just put it on the wire and return
        if (use_custom_payload) {
            is_executed = true;
            send ();

            return;
        }

        //  REST POST requests must transmit at least one argument
        if (get_method () == HttpMethod.POST)
            assert (arguments.length > 0);

        // concatenate the REST arguments array into an HTTP formdata string
        string formdata_string = "";
        for (int i = 0; i < arguments.length; i++) {
            formdata_string += ("%s=%s".printf (arguments[i].key, arguments[i].value));
            if (i < arguments.length - 1)
                formdata_string += "&";
        }

        // for GET requests with arguments, append the formdata string to the endpoint url after a
        // query divider ('?') -- but make sure to save the old (caller-specified) endpoint URL
        // and restore it after the GET so that the underlying Soup message remains consistent
        string old_url = null;
        string url_with_query = null;
        if (get_method () == HttpMethod.GET && arguments.length > 0) {
            old_url = message.get_uri ().to_string (false);
            url_with_query = get_endpoint_url () + "?" + formdata_string;
            message.set_uri (new Soup.URI (url_with_query));
        } else {
            message.set_request ("application/x-www-form-urlencoded", Soup.MemoryUse.COPY,
            formdata_string.data);
        }

        is_executed = true;

        try {
            debug ("sending message to URI = '%s'", message.get_uri ().to_string (false));
            send ();
        } finally {
            // if old_url is non-null, then restore it
            if (old_url != null)
                message.set_uri (new Soup.URI (old_url));
        }
    }

    public string get_response () {
        assert (get_is_executed ());
        return (string) message.response_body.data;
    }

    public unowned Soup.MessageHeaders get_response_headers () {
        assert (get_is_executed ());
        return message.response_headers;
    }

    public void add_argument (string name, string value) {
        arguments += new Argument (name, value);
    }

    public string? get_endpoint_url () {
        return (endpoint_url != null) ? endpoint_url : parent_session.get_endpoint_url ();
    }

    public Session get_parent_session () {
        return parent_session;
    }
}

public class UploadTransaction : Transaction {
    protected GLib.HashTable<string, string> binary_disposition_table = null;
    protected Spit.Publishing.Publishable publishable = null;
    protected string mime_type;
    protected Gee.HashMap<string, string> message_headers = null;

    public UploadTransaction (Session session, Spit.Publishing.Publishable publishable) {
        base (session);
        this.publishable = publishable;
        this.mime_type = media_type_to_mime_type (publishable.get_media_type ());

        binary_disposition_table = create_default_binary_disposition_table ();

        message_headers = new Gee.HashMap<string, string> ();
    }

    public UploadTransaction.with_endpoint_url (Session session,
            Spit.Publishing.Publishable publishable, string endpoint_url) {
        base.with_endpoint_url (session, endpoint_url);
        this.publishable = publishable;
        this.mime_type = media_type_to_mime_type (publishable.get_media_type ());

        binary_disposition_table = create_default_binary_disposition_table ();

        message_headers = new Gee.HashMap<string, string> ();
    }

    protected override void add_header (string key, string value) {
        message_headers.set (key, value);
    }

    private static string media_type_to_mime_type (Spit.Publishing.Publisher.MediaType media_type) {
        if (media_type == Spit.Publishing.Publisher.MediaType.PHOTO)
            return "image/jpeg";
        else if (media_type == Spit.Publishing.Publisher.MediaType.VIDEO)
            return "video/mpeg";
        else
            error ("UploadTransaction: unknown media type %s.", media_type.to_string ());
    }

    private GLib.HashTable<string, string> create_default_binary_disposition_table () {
        GLib.HashTable<string, string> result =
            new GLib.HashTable<string, string> (GLib.str_hash, GLib.str_equal);

        result.insert ("filename", Soup.URI.encode (publishable.get_serialized_file ().get_basename (),
                       null));

        return result;
    }

    protected void set_binary_disposition_table (GLib.HashTable<string, string> new_disp_table) {
        binary_disposition_table = new_disp_table;
    }

    public override void execute () throws Spit.Publishing.PublishingError {
        Argument[] request_arguments = get_arguments ();
        assert (request_arguments.length > 0);

        Soup.Multipart message_parts = new Soup.Multipart ("multipart/form-data");

        foreach (Argument arg in request_arguments)
            message_parts.append_form_string (arg.key, arg.value);

        string payload;
        size_t payload_length;
        try {
            FileUtils.get_contents (publishable.get_serialized_file ().get_path (), out payload,
            out payload_length);
        } catch (FileError e) {
            throw new Spit.Publishing.PublishingError.LOCAL_FILE_ERROR (
                _ ("A temporary file needed for publishing is unavailable"));
        }

        int payload_part_num = message_parts.get_length ();

        Soup.Buffer bindable_data = new Soup.Buffer.take (payload.data[0:payload_length]);
        message_parts.append_form_file ("", publishable.get_serialized_file ().get_path (), mime_type,
        bindable_data);

        unowned Soup.MessageHeaders image_part_header;
        unowned Soup.Buffer image_part_body;
        message_parts.get_part (payload_part_num, out image_part_header, out image_part_body);
        image_part_header.set_content_disposition ("form-data", binary_disposition_table);

        Soup.Message outbound_message =
        soup_form_request_new_from_multipart (get_endpoint_url (), message_parts);
        // TODO: there must be a better way to iterate over a map
        Gee.MapIterator<string, string> i = message_headers.map_iterator ();
        bool cont = i.next ();
        while (cont) {
            outbound_message.request_headers.append (i.get_key (), i.get_value ());
            cont = i.next ();
        }
        set_message (outbound_message);

        set_is_executed (true);
        send ();
    }
}

public class XmlDocument {
    // Returns non-null string if an error condition is discovered in the XML (such as a well-known
    // node).  The string is used when generating a PublishingError exception.  This delegate does
    // not need to check for general-case malformed XML.
    public delegate string? CheckForErrorResponse (XmlDocument doc);

    private Xml.Doc *document;

    private XmlDocument (Xml.Doc *doc) {
        document = doc;
    }

    ~XmlDocument () {
        delete document;
    }

    public Xml.Node *get_root_node () {
        return document->get_root_element ();
    }

    public Xml.Node *get_named_child (Xml.Node *parent, string child_name)
    throws Spit.Publishing.PublishingError {
        Xml.Node *doc_node_iter = parent->children;

        for ( ; doc_node_iter != null; doc_node_iter = doc_node_iter->next) {
            if (doc_node_iter->name == child_name)
                return doc_node_iter;
        }

        throw new Spit.Publishing.PublishingError.MALFORMED_RESPONSE ("Can't find XML node %s",
        child_name);
    }

    public string get_property_value (Xml.Node *node, string property_key)
    throws Spit.Publishing.PublishingError {
        string value_string = node->get_prop (property_key);
        if (value_string == null)
            throw new Spit.Publishing.PublishingError.MALFORMED_RESPONSE ("Can't find XML " +
            "property %s on node %s", property_key, node->name);

        return value_string;
    }

    public static XmlDocument parse_string (string? input_string,
                                            CheckForErrorResponse check_for_error_response) throws Spit.Publishing.PublishingError {
        if (input_string == null || input_string.length == 0)
            throw new Spit.Publishing.PublishingError.MALFORMED_RESPONSE ("Empty XML string");

        // Does this even start and end with the right characters?
        if (!input_string.chug ().chomp ().has_prefix ("<") ||
        !input_string.chug ().chomp ().has_suffix (">")) {
            // Didn't start or end with a < or > and can't be parsed as XML - treat as malformed.
            throw new Spit.Publishing.PublishingError.MALFORMED_RESPONSE ("Unable to parse XML " +
            "document");
        }

        // Don't want blanks to be included as text nodes, and want the XML parser to tolerate
        // tolerable XML
        Xml.Doc *doc = Xml.Parser.read_memory (input_string, (int) input_string.length, null, null,
        Xml.ParserOption.NOBLANKS | Xml.ParserOption.RECOVER);
        if (doc == null)
            throw new Spit.Publishing.PublishingError.MALFORMED_RESPONSE ("Unable to parse XML " +
            "document");

        // Since 'doc' is the top level, if it has no children, something is wrong
        // with the XML; we cannot continue normally here.
        if (doc->children == null) {
            throw new Spit.Publishing.PublishingError.MALFORMED_RESPONSE ("Unable to parse XML " +
            "document");
        }

        XmlDocument rest_doc = new XmlDocument (doc);

        string? result = check_for_error_response (rest_doc);
        if (result != null)
            throw new Spit.Publishing.PublishingError.SERVICE_ERROR ("%s", result);

        return rest_doc;
    }
}

/* Encoding strings in XML decimal encoding is a relatively esoteric operation. Most web services
   prefer to have non-ASCII character entities encoded using "symbolic encoding," where common
   entities are encoded in short, symbolic names (e.g. "ñ" -> &ntilde;). Picasa Web Albums,
   however, doesn't like symbolic encoding, and instead wants non-ASCII entities encoded directly
   as their Unicode code point numbers (e.g. "ñ" -> &241;). */
public string decimal_entity_encode (string source) {
    StringBuilder encoded_str_builder = new StringBuilder ();
    string current_char = source;
    while (true) {
        int current_char_value = (int) (current_char.get_char_validated ());

        // null character signals end of string
        if (current_char_value < 1)
            break;

        // no need to escape ASCII characters except the ampersand, greater-than sign and less-than
        // signs, which are special in the world of XML
        if ((current_char_value < 128) && (current_char_value != '&') && (current_char_value != '<') &&
                (current_char_value != '>'))
            encoded_str_builder.append_unichar (current_char.get_char_validated ());
        else
            encoded_str_builder.append ("&#%d;".printf (current_char_value));

        current_char = current_char.next_char ();
    }

    return encoded_str_builder.str;
}

internal abstract class BatchUploader {
    private int current_file = 0;
    private Spit.Publishing.Publishable[] publishables = null;
    private Session session = null;
    private unowned Spit.Publishing.ProgressCallback? status_updated = null;

    public signal void upload_complete (int num_photos_published);
    public signal void upload_error (Spit.Publishing.PublishingError err);

    protected BatchUploader (Session session, Spit.Publishing.Publishable[] publishables) {
        this.publishables = publishables;
        this.session = session;
    }

    private void send_files () {
        current_file = 0;
        bool stop = false;
        foreach (Spit.Publishing.Publishable publishable in publishables) {
            GLib.File? file = publishable.get_serialized_file ();

            // if the current publishable hasn't been serialized, then skip it
            if (file == null) {
                current_file++;
                continue;
            }

            double fraction_complete = ((double) current_file) / publishables.length;
            if (status_updated != null)
                status_updated (current_file + 1, fraction_complete);

            Transaction txn = create_transaction (publishables[current_file]);

            txn.chunk_transmitted.connect (on_chunk_transmitted);

            try {
                txn.execute ();
            } catch (Spit.Publishing.PublishingError err) {
                upload_error (err);
                stop = true;
            }

            txn.chunk_transmitted.disconnect (on_chunk_transmitted);

            if (stop)
                break;

            current_file++;
        }

        if (!stop)
            upload_complete (current_file);
    }

    private void on_chunk_transmitted (int bytes_written_so_far, int total_bytes) {
        double file_span = 1.0 / publishables.length;
        double this_file_fraction_complete = ((double) bytes_written_so_far) / total_bytes;
        double fraction_complete = (current_file * file_span) + (this_file_fraction_complete *
                                   file_span);

        if (status_updated != null)
            status_updated (current_file + 1, fraction_complete);
    }

    protected Session get_session () {
        return session;
    }

    protected Spit.Publishing.Publishable get_current_publishable () {
        return publishables[current_file];
    }

    protected abstract Transaction create_transaction (Spit.Publishing.Publishable publishable);

    public void upload (Spit.Publishing.ProgressCallback? status_updated = null) {
        this.status_updated = status_updated;

        if (publishables.length > 0)
            send_files ();
    }
}

// Remove diacritics in a string, yielding ASCII.  If the given string is in
// a character set not based on Latin letters (e.g. Cyrillic), the result
// may be empty.
public string asciify_string (string s) {
    string t = s.normalize ();  // default normalization yields a maximally decomposed form

    StringBuilder b = new StringBuilder ();
    for (unowned string u = t; u.get_char () != 0 ; u = u.next_char ()) {
        unichar c = u.get_char ();
        if ((int) c < 128)
            b.append_unichar (c);
    }

    return b.str;
}

/** @brief Work-around for a problem in libgee where a TreeSet can leak references when it
 * goes out of scope; please see https://bugzilla.gnome.org/show_bug.cgi?id=695045 for more
 * details. This class merely wraps it and adds a call to clear () to the destructor.
 */
public class FixedTreeSet<G> : Gee.TreeSet<G> {
    public FixedTreeSet (owned CompareDataFunc<G>? comp_func = null) {
        base ((owned) comp_func);
    }

    ~FixedTreeSet () {
        clear ();
    }
}

public abstract class GoogleSession : Session {
    public abstract string get_user_name ();
    public abstract string get_access_token ();
    public abstract string get_refresh_token ();
    public abstract void deauthenticate ();
}

public abstract class GooglePublisher : Object, Spit.Publishing.Publisher {
    private const string OAUTH_CLIENT_ID = "1073902228337-gm4uf5etk25s0hnnm0g7uv2tm2bm1j0b.apps.googleusercontent.com";
    private const string OAUTH_CLIENT_SECRET = "_kA4RZz72xqed4DqfO7xMmMN";

    private class GoogleSessionImpl : GoogleSession {
        public string? access_token;
        public string? user_name;
        public string? refresh_token;

        public GoogleSessionImpl () {
            this.access_token = null;
            this.user_name = null;
            this.refresh_token = null;
        }

        public override bool is_authenticated () {
            return (access_token != null);
        }

        public override string get_user_name () {
            assert (user_name != null);
            return user_name;
        }

        public override string get_access_token () {
            assert (is_authenticated ());
            return access_token;
        }

        public override string get_refresh_token () {
            assert (refresh_token != null);
            return refresh_token;
        }

        public override void deauthenticate () {
            access_token = null;
            user_name = null;
            refresh_token = null;
        }
    }

    private class WebAuthenticationPane : Spit.Publishing.DialogPane, Object {
        public static bool cache_dirty = false;

        private WebKit.WebView webview;
        private Gtk.Box pane_widget;
        private Gtk.ScrolledWindow webview_frame;
        private string auth_sequence_start_url;

        public signal void authorized (string auth_code);

        public WebAuthenticationPane (string auth_sequence_start_url) {
            this.auth_sequence_start_url = auth_sequence_start_url;

            pane_widget = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            webview_frame = new Gtk.ScrolledWindow (null, null);
            webview_frame.set_shadow_type (Gtk.ShadowType.ETCHED_IN);
            webview_frame.set_policy (Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC);
            webview_frame.expand = true;

            webview = new WebKit.WebView ();
            webview.load_changed.connect ((load_event) => {
                if (load_event == WebKit.LoadEvent.STARTED) {
                    on_load_started ();
                } else if (load_event == WebKit.LoadEvent.FINISHED) {
                    on_page_load ();
                }
            });

            webview_frame.add (webview);
            pane_widget.pack_start (webview_frame, true, true, 0);
        }

        public static bool is_cache_dirty () {
            return cache_dirty;
        }

        private void on_page_load () {
            pane_widget.get_window ().set_cursor (new Gdk.Cursor.for_display (Gdk.Display.get_default (), Gdk.CursorType.LEFT_PTR));

            string page_title = webview.get_title ();
            if (page_title.index_of ("state=connect") > 0) {
                int auth_code_field_start = page_title.index_of ("code=");
                if (auth_code_field_start < 0)
                    return;

                string auth_code =
                    page_title.substring (auth_code_field_start + 5); // 5 = "code=".length

                cache_dirty = true;

                authorized (auth_code);
            }
        }

        private void on_load_started () {
            pane_widget.get_window ().set_cursor (new Gdk.Cursor.for_display (Gdk.Display.get_default (), Gdk.CursorType.WATCH));
        }

        public Spit.Publishing.DialogPane.GeometryOptions get_preferred_geometry () {
            return Spit.Publishing.DialogPane.GeometryOptions.NONE;
        }

        public Gtk.Widget get_widget () {
            return pane_widget;
        }

        public void on_pane_installed () {
            webview.load_uri (auth_sequence_start_url);
        }

        public void on_pane_uninstalled () {
        }
    }

    private class GetAccessTokensTransaction : Publishing.RESTSupport.Transaction {
        private const string ENDPOINT_URL = "https://accounts.google.com/o/oauth2/token";

        public GetAccessTokensTransaction (Session session, string auth_code) {
            base.with_endpoint_url (session, ENDPOINT_URL);

            add_argument ("code", auth_code);
            add_argument ("client_id", OAUTH_CLIENT_ID);
            add_argument ("client_secret", OAUTH_CLIENT_SECRET);
            add_argument ("redirect_uri", "urn:ietf:wg:oauth:2.0:oob");
            add_argument ("grant_type", "authorization_code");
        }
    }

    private class RefreshAccessTokenTransaction : Publishing.RESTSupport.Transaction {
        private const string ENDPOINT_URL = "https://accounts.google.com/o/oauth2/token";

        public RefreshAccessTokenTransaction (Session session) {
            base.with_endpoint_url (session, ENDPOINT_URL);

            add_argument ("client_id", OAUTH_CLIENT_ID);
            add_argument ("client_secret", OAUTH_CLIENT_SECRET);
            add_argument ("refresh_token", ((GoogleSession) session).get_refresh_token ());
            add_argument ("grant_type", "refresh_token");
        }
    }

    public class AuthenticatedTransaction : Publishing.RESTSupport.Transaction {
        private AuthenticatedTransaction.with_endpoint_url (GoogleSession session,
                string endpoint_url, Publishing.RESTSupport.HttpMethod method) {
            base.with_endpoint_url (session, endpoint_url, method);
        }

        public AuthenticatedTransaction (GoogleSession session, string endpoint_url,
                                         Publishing.RESTSupport.HttpMethod method) {
            base.with_endpoint_url (session, endpoint_url, method);
            assert (session.is_authenticated ());

            add_header ("Authorization", "Bearer " + session.get_access_token ());
        }
    }

    private class UsernameFetchTransaction : AuthenticatedTransaction {
        private const string ENDPOINT_URL = "https://www.googleapis.com/oauth2/v1/userinfo";

        public UsernameFetchTransaction (GoogleSession session) {
            base (session, ENDPOINT_URL, Publishing.RESTSupport.HttpMethod.GET);
        }
    }

    private string scope;
    private GoogleSessionImpl session;
    private WebAuthenticationPane? web_auth_pane;
    private weak Spit.Publishing.PluginHost host;
    private weak Spit.Publishing.Service service;

    protected GooglePublisher (Spit.Publishing.Service service, Spit.Publishing.PluginHost host,
                               string scope) {
        this.scope = scope;
        this.session = new GoogleSessionImpl ();
        this.service = service;
        this.host = host;
        this.web_auth_pane = null;
    }

    private void on_web_auth_pane_authorized (string auth_code) {
        web_auth_pane.authorized.disconnect (on_web_auth_pane_authorized);

        debug ("EVENT: user authorized scope %s with auth_code %s", scope, auth_code);

        if (!is_running ())
            return;

        do_get_access_tokens (auth_code);
    }

    private void on_get_access_tokens_complete (Publishing.RESTSupport.Transaction txn) {
        txn.completed.disconnect (on_get_access_tokens_complete);
        txn.network_error.disconnect (on_get_access_tokens_error);

        debug ("EVENT: network transaction to exchange authorization code for access tokens " +
               "completed successfully.");

        if (!is_running ())
            return;

        do_extract_tokens (txn.get_response ());
    }

    private void on_get_access_tokens_error (Publishing.RESTSupport.Transaction txn,
            Spit.Publishing.PublishingError err) {
        txn.completed.disconnect (on_get_access_tokens_complete);
        txn.network_error.disconnect (on_get_access_tokens_error);

        debug ("EVENT: network transaction to exchange authorization code for access tokens " +
               "failed; response = '%s'", txn.get_response ());

        if (!is_running ())
            return;

        host.post_error (err);
    }

    private void on_refresh_access_token_transaction_completed (Publishing.RESTSupport.Transaction
            txn) {
        txn.completed.disconnect (on_refresh_access_token_transaction_completed);
        txn.network_error.disconnect (on_refresh_access_token_transaction_error);

        debug ("EVENT: refresh access token transaction completed successfully.");

        if (!is_running ())
            return;

        if (session.is_authenticated ()) // ignore these events if the session is already auth'd
            return;

        do_extract_tokens (txn.get_response ());
    }

    private void on_refresh_access_token_transaction_error (Publishing.RESTSupport.Transaction txn,
            Spit.Publishing.PublishingError err) {
        txn.completed.disconnect (on_refresh_access_token_transaction_completed);
        txn.network_error.disconnect (on_refresh_access_token_transaction_error);

        debug ("EVENT: refresh access token transaction caused a network error.");

        if (!is_running ())
            return;

        if (session.is_authenticated ()) // ignore these events if the session is already auth'd
            return;

        // 400 errors indicate that the OAuth client ID and secret have become invalid. In most
        // cases, this can be fixed by logging the user out
        if (txn.get_status_code () == 400) {
            do_logout ();
            return;
        }

        host.post_error (err);
    }

    private void on_refresh_token_available (string token) {
        debug ("EVENT: an OAuth refresh token has become available; token = '%s'.", token);

        if (!is_running ())
            return;

        session.refresh_token = token;
    }

    private void on_access_token_available (string token) {
        debug ("EVENT: an OAuth access token has become available; token = '%s'.", token);

        if (!is_running ())
            return;

        session.access_token = token;

        do_fetch_username ();
    }

    private void on_fetch_username_transaction_completed (Publishing.RESTSupport.Transaction txn) {
        txn.completed.disconnect (on_fetch_username_transaction_completed);
        txn.network_error.disconnect (on_fetch_username_transaction_error);

        debug ("EVENT: username fetch transaction completed successfully.");

        if (!is_running ())
            return;

        do_extract_username (txn.get_response ());
    }

    private void on_fetch_username_transaction_error (Publishing.RESTSupport.Transaction txn,
            Spit.Publishing.PublishingError err) {
        txn.completed.disconnect (on_fetch_username_transaction_completed);
        txn.network_error.disconnect (on_fetch_username_transaction_error);

        debug ("EVENT: username fetch transaction caused a network error");

        if (!is_running ())
            return;

        host.post_error (err);
    }

    private void do_get_access_tokens (string auth_code) {
        debug ("ACTION: exchanging authorization code for access & refresh tokens");

        host.install_login_wait_pane ();

        GetAccessTokensTransaction tokens_txn = new GetAccessTokensTransaction (session, auth_code);
        tokens_txn.completed.connect (on_get_access_tokens_complete);
        tokens_txn.network_error.connect (on_get_access_tokens_error);

        try {
            tokens_txn.execute ();
        } catch (Spit.Publishing.PublishingError err) {
            host.post_error (err);
        }
    }

    private void do_hosted_web_authentication () {
        debug ("ACTION: running OAuth authentication flow in hosted web pane.");

        string user_authorization_url = "https://accounts.google.com/o/oauth2/auth?" +
                                        "response_type=code&" +
                                        "client_id=" + OAUTH_CLIENT_ID + "&" +
                                        "redirect_uri=" + Soup.URI.encode ("urn:ietf:wg:oauth:2.0:oob", null) + "&" +
                                        "scope=" + Soup.URI.encode (scope, null) + "+" +
                                        Soup.URI.encode ("https://www.googleapis.com/auth/userinfo.profile", null) + "&" +
                                        "state=connect&" +
                                        "access_type=offline&" +
                                        "approval_prompt=force";

        web_auth_pane = new WebAuthenticationPane (user_authorization_url);
        web_auth_pane.authorized.connect (on_web_auth_pane_authorized);

        host.install_dialog_pane (web_auth_pane);

    }

    private void do_exchange_refresh_token_for_access_token () {
        debug ("ACTION: exchanging OAuth refresh token for OAuth access token.");

        host.install_login_wait_pane ();

        RefreshAccessTokenTransaction txn = new RefreshAccessTokenTransaction (session);

        txn.completed.connect (on_refresh_access_token_transaction_completed);
        txn.network_error.connect (on_refresh_access_token_transaction_error);

        try {
            txn.execute ();
        } catch (Spit.Publishing.PublishingError err) {
            host.post_error (err);
        }
    }

    private void do_extract_tokens (string response_body) {
        debug ("ACTION: extracting OAuth tokens from body of server response");

        Json.Parser parser = new Json.Parser ();

        try {
            parser.load_from_data (response_body);
        } catch (Error err) {
            host.post_error (new Spit.Publishing.PublishingError.MALFORMED_RESPONSE (
                                 "Couldn't parse JSON response: " + err.message));
            return;
        }

        Json.Object response_obj = parser.get_root ().get_object ();

        if ((!response_obj.has_member ("access_token")) && (!response_obj.has_member ("refresh_token"))) {
            host.post_error (new Spit.Publishing.PublishingError.MALFORMED_RESPONSE (
                                 "neither access_token nor refresh_token not present in server response"));
            return;
        }

        if (response_obj.has_member ("refresh_token")) {
            string refresh_token = response_obj.get_string_member ("refresh_token");

            if (refresh_token != "")
                on_refresh_token_available (refresh_token);
        }

        if (response_obj.has_member ("access_token")) {
            string access_token = response_obj.get_string_member ("access_token");

            if (access_token != "")
                on_access_token_available (access_token);
        }
    }

    private void do_fetch_username () {
        debug ("ACTION: running network transaction to fetch username.");

        host.install_login_wait_pane ();
        host.set_service_locked (true);

        UsernameFetchTransaction txn = new UsernameFetchTransaction (session);
        txn.completed.connect (on_fetch_username_transaction_completed);
        txn.network_error.connect (on_fetch_username_transaction_error);

        try {
            txn.execute ();
        } catch (Error err) {
            host.post_error (err);
        }
    }

    private void do_extract_username (string response_body) {
        debug ("ACTION: extracting username from body of server response");

        Json.Parser parser = new Json.Parser ();

        try {
            parser.load_from_data (response_body);
        } catch (Error err) {
            host.post_error (new Spit.Publishing.PublishingError.MALFORMED_RESPONSE (
                                 "Couldn't parse JSON response: " + err.message));
            return;
        }

        Json.Object response_obj = parser.get_root ().get_object ();

        if (response_obj.has_member ("name")) {
            string username = response_obj.get_string_member ("name");

            if (username != "")
                session.user_name = username;
        }

        if (response_obj.has_member ("access_token")) {
            string access_token = response_obj.get_string_member ("access_token");

            if (access_token != "")
                session.access_token = access_token;
        }

        // by the time we get a username, the session should be authenticated, or else something
        // really tragic has happened
        assert (session.is_authenticated ());

        on_login_flow_complete ();
    }

    protected unowned Spit.Publishing.PluginHost get_host () {
        return host;
    }

    protected GoogleSession get_session () {
        return session;
    }

    protected void start_oauth_flow (string? refresh_token = null) {
        if (refresh_token != null && refresh_token != "") {
            session.refresh_token = refresh_token;
            do_exchange_refresh_token_for_access_token ();
        } else {
            if (WebAuthenticationPane.is_cache_dirty ()) {
                host.install_static_message_pane (_ ("You have already logged in and out of a Google service during this session.\n\nTo continue publishing to Google services, quit and restart this software, then try publishing again."));
                return;
            }

            do_hosted_web_authentication ();
        }
    }

    protected abstract void on_login_flow_complete ();

    protected abstract void do_logout ();

    public abstract bool is_running ();

    public abstract void start ();

    public abstract void stop ();

    public Spit.Publishing.Service get_service () {
        return service;
    }
}
}
