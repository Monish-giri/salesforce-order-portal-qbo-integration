public without sharing class OrderlyLoginController {
    @AuraEnabled
    public static String login(String username, String password, String startUrl) {
        if (String.isBlank(username) || String.isBlank(password)) {
            throw new AuraHandledException('Enter your username and password.');
        }
        try {
            PageReference destination = Site.login(username, password, String.isBlank(startUrl) ? '/' : startUrl);
            return destination == null ? null : destination.getUrl();
        } catch (Exception ex) {
            throw new AuraHandledException('Invalid username or password. Please try again.');
        }
    }
}