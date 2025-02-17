public abstract class StreamingMonitorController {
    public final static String EVT_PUSH_TOPIC = 'PushTopicEvent';
    public final static String EVT_GENERIC = 'GenericEvent';
    public final static String EVT_STD_PLATFORM_EVENT = 'StandardPlatformEvent';
    public final static String EVT_PLATFORM_EVENT = 'PlatformEvent';
    public final static String EVT_CDC_STANDARD = 'ChangeDataCaptureEvent';
    public final static String EVT_CUSTOM_CHANNEL_CDC = 'CustomChannelCDC';
    public final static String EVT_CUSTOM_CHANNEL_PE = 'CustomChannelPE';
    public final static String EVT_MONITORING = 'MonitoringEvent';

    private final static List<String> MONITORING_EVENTS = new List<String>{
        'ApiAnomalyEvent',
        'ApiEventStream',
        'BulkApiResultEvent',
        'ConcurLongRunApexErrEvent',
        'ConsentEvent',
        'CredentialStuffingEvent',
        'FileEvent',
        'LightningUriEventStream',
        'ListViewEventStream',
        'LoginAsEventStream',
        'LoginEventStream',
        'LogoutEventStream',
        'MobileEmailEvent',
        'MobileEnforcedPolicyEvent',
        'MobileScreenshotEvent',
        'MobileTelephonyEvent',
        'PermissionSetEvent',
        'ReportAnomalyEvent',
        'ReportEventStream',
        'SessionHijackingEvent',
        'UriEventStream'
    };

    @AuraEnabled
    public static void publishStreamingEvent(
        String eventType,
        String eventName,
        String eventPayload
    ) {
        if (eventType == EVT_PLATFORM_EVENT) {
            publishPlatformEvent(eventName, eventPayload);
        } else if (eventType == EVT_GENERIC) {
            publishGenericEvent(eventName, eventPayload);
        } else {
            throw new StreamingException(
                'Unsupported event type: ' + eventType
            );
        }
    }

    @AuraEnabled
    public static Map<String, List<ComboBoxItem>> getAllEventChannels() {
        return new Map<String, List<ComboBoxItem>>{
            EVT_PUSH_TOPIC => getPushTopicEventChannels(),
            EVT_GENERIC => getGenericEventChannels(),
            EVT_STD_PLATFORM_EVENT => getStandardPlatformEventChannels(),
            EVT_PLATFORM_EVENT => getPlatformEventChannels(),
            EVT_CDC_STANDARD => getChangeDataCaptureEventChannels(),
            EVT_CUSTOM_CHANNEL_CDC => new List<ComboBoxItem>(),
            EVT_CUSTOM_CHANNEL_PE => new List<ComboBoxItem>(),
            EVT_MONITORING => getEventMonitoringChannels()
        };
    }

    @AuraEnabled
    public static List<OrgLimitWrapper> getOrgLimits() {
        // Can't output directly OrgLimit so we have to use a wrapper
        List<OrgLimitWrapper> output = new List<OrgLimitWrapper>();
        List<OrgLimit> limits = OrgLimits.getAll();
        for (OrgLimit l : limits) {
            if (l.getLimit() != null && l.getValue() != null) {
                output.add(new OrgLimitWrapper(l));
            }
        }
        return output;
    }

    @AuraEnabled
    public static List<PlatformEventUsageMetric> getEventUsageMetrics() {
        return [
            SELECT Name, StartDate, Value
            FROM PlatformEventUsageMetric
            ORDER BY StartDate
        ];
    }

    private static void publishPlatformEvent(
        String eventName,
        String eventPayload
    ) {
        // Load event type
        Type platformEventType = Type.forName(null, eventName);
        if (platformEventType == null) {
            throw new StreamingException(
                'Unknown platform event type: ' + eventName
            );
        }
        // Create event instance
        SObject event;
        try {
            event = (SObject) JSON.deserialize(eventPayload, platformEventType);
        } catch (Exception e) {
            System.debug(e);
            System.debug(e.getCause());
            throw new StreamingException(
                'Failed to instantiate ' +
                    eventName +
                    ' platform event with provided data: ' +
                    eventPayload
            );
        }
        // Publish event
        Database.SaveResult result = Eventbus.publish(event);
        if (!result.isSuccess()) {
            String errorMessage =
                'Failed to publish ' +
                eventName +
                ': EventBus publish error.';
            System.debug(errorMessage);
            for (Database.Error error : result.getErrors()) {
                System.debug(
                    'Error: ' +
                        error.getStatusCode() +
                        ' - ' +
                        error.getMessage() +
                        ' - ' +
                        error.getFields()
                );
            }
            throw new StreamingException(errorMessage);
        }
    }

    private static void publishGenericEvent(
        String eventName,
        String eventPayload
    ) {
        // Load event type
        String channel = '/u/' + eventName;
        List<StreamingChannel> channels = [
            SELECT Id
            FROM StreamingChannel
            WHERE Name = :channel
            LIMIT 1
        ];
        if (channels.size() != 1) {
            throw new StreamingException(
                'Unknown generic event type: ' + eventName
            );
        }
        // Posting event in a job in order to be able to call the REST API
        System.enqueueJob(
            new QueueableGenericEventPost(channels[0].Id, eventPayload)
        );
    }

    @TestVisible
    private static List<ComboBoxItem> getPushTopicEventChannels() {
        List<PushTopic> topics = [SELECT Name FROM PushTopic ORDER BY Name];
        List<ComboBoxItem> items = new List<ComboBoxItem>();
        for (PushTopic topic : topics) {
            items.add(new ComboBoxItem(topic.Name, topic.Name));
        }
        return items;
    }

    @TestVisible
    private static List<ComboBoxItem> getGenericEventChannels() {
        List<StreamingChannel> channels = [
            SELECT Name
            FROM StreamingChannel
            ORDER BY Name
        ];
        List<ComboBoxItem> items = new List<ComboBoxItem>();
        for (StreamingChannel channel : channels) {
            String name = channel.Name.substring(3);
            items.add(new ComboBoxItem(name, name));
        }
        return items;
    }

    @TestVisible
    private static List<ComboBoxItem> getChangeDataCaptureEventChannels() {
        List<ComboBoxItem> items = new List<ComboBoxItem>();
        // Standard CDC
        List<EntityDefinition> standardCdc = [
            SELECT Label, QualifiedApiName
            FROM EntityDefinition
            WHERE PublisherId = 'CDC'
        ];
        for (EntityDefinition entity : standardCdc) {
            items.add(new ComboBoxItem(entity.Label, entity.QualifiedApiName));
        }
        // Custom CDC
        List<EntityDefinition> customCdc = [
            SELECT Label, QualifiedApiName
            FROM EntityDefinition
            WHERE PublisherId = '<local>'
        ];
        for (EntityDefinition entity : customCdc) {
            String apiName = entity.QualifiedApiName;
            if (apiName.endsWith('__c')) {
                items.add(
                    new ComboBoxItem(
                        entity.Label + ' Change Event',
                        apiName.replace('__c', '__ChangeEvent')
                    )
                );
            }
        }

        items.sort();
        return items;
    }

    @TestVisible
    private static List<ComboBoxItem> getPlatformEventChannels() {
        List<EntityDefinition> entities = [
            SELECT Label, QualifiedApiName, IsCustomizable
            FROM EntityDefinition
            WHERE IsCustomizable = TRUE AND QualifiedApiName LIKE '%e'
            ORDER BY Label ASC
        ];
        List<ComboBoxItem> items = new List<ComboBoxItem>();
        for (EntityDefinition entity : entities) {
            if (entity.QualifiedApiName.endsWith('__e')) {
                items.add(
                    new ComboBoxItem(entity.Label, entity.QualifiedApiName)
                );
            }
        }
        return items;
    }

    @TestVisible
    private static List<ComboBoxItem> getStandardPlatformEventChannels() {
        List<EntityDefinition> entities = [
            SELECT Label, QualifiedApiName, IsCustomizable
            FROM EntityDefinition
            WHERE IsCustomizable = FALSE AND IsEverCreatable = TRUE
            ORDER BY Label ASC
        ];
        List<ComboBoxItem> items = new List<ComboBoxItem>();
        for (EntityDefinition entity : entities) {
            if (
                entity.QualifiedApiName.endsWith('Event') &&
                !entity.QualifiedApiName.endsWith('ChangeEvent')
            ) {
                items.add(
                    new ComboBoxItem(entity.Label, entity.QualifiedApiName)
                );
            }
        }
        return items;
    }

    @TestVisible
    private static List<ComboBoxItem> getEventMonitoringChannels() {
        List<ComboBoxItem> items = new List<ComboBoxItem>();
        for (String eventName : MONITORING_EVENTS) {
            items.add(new ComboBoxItem(eventName, eventName));
        }
        return items;
    }

    public class ComboBoxItem implements Comparable {
        @AuraEnabled
        public String label;

        @AuraEnabled
        public String value;

        public ComboBoxItem(String label, String value) {
            this.label = label;
            this.value = value;
        }

        public Integer compareTo(Object other) {
            return this.label.compareTo(((ComboBoxItem) other).label);
        }
    }

    public class OrgLimitWrapper {
        @AuraEnabled
        public String name;

        @AuraEnabled
        public Integer value;

        @AuraEnabled
        public Integer max;

        public OrgLimitWrapper(OrgLimit orgLimit) {
            this.name = orgLimit.getName();
            this.value = orgLimit.getValue();
            this.max = orgLimit.getLimit();
        }
    }

    @TestVisible
    private class QueueableGenericEventPost implements Queueable, Database.AllowsCallouts {
        private String channelId;
        private String payload;

        public QueueableGenericEventPost(String channelId, String payload) {
            this.channelId = channelId;
            this.payload = payload;
        }

        public void execute(QueueableContext context) {
            String restAPIURL =
                URL.getOrgDomainUrl().toExternalForm() +
                '/services/data/v60.0/sobjects/StreamingChannel/' +
                channelId +
                '/push';
            HttpRequest httpRequest = new HttpRequest();
            httpRequest.setMethod('POST');
            httpRequest.setHeader('Content-Type', 'application/json');
            httpRequest.setHeader(
                'Authorization',
                'Bearer ' + UserInfo.getSessionID()
            );
            httpRequest.setEndpoint(restAPIURL);
            httpRequest.setBody(
                '{ "pushEvents": [ { "payload": "' +
                    payload +
                    '", "userIds": [] } ] }'
            );
            Http http = new Http();
            HttpResponse httpResponse = http.send(httpRequest);
            if (httpResponse.getStatusCode() != 200) {
                System.debug(
                    'HTTP ' +
                        httpResponse.getStatusCode() +
                        ': ' +
                        httpResponse.getBody()
                );
                throw new CalloutException(httpResponse.getBody());
            }
        }
    }

    public class StreamingException extends Exception {
    }
}
