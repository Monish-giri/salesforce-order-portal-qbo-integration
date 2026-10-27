@IsTest
private class PortalProfileServiceTest {
    @IsTest
    static void rejectsMissingPhoto() {
        Test.startTest();
        try {
            PortalProfileService.updateProfilePhoto(null, 'profile.jpg', 'image/jpeg');
            System.assert(false, 'Expected an exception for a missing image.');
        } catch (AuraHandledException ex) {
            System.assert(ex.getMessage().contains('choose an image'));
        }
        Test.stopTest();
    }

    @IsTest
    static void rejectsUnsupportedImageType() {
        Test.startTest();
        try {
            PortalProfileService.updateProfilePhoto(
                EncodingUtil.base64Encode(Blob.valueOf('test-image')),
                'profile.txt',
                'text/plain'
            );
            System.assert(false, 'Expected an exception for an unsupported image type.');
        } catch (AuraHandledException ex) {
            System.assert(ex.getMessage().contains('JPG, PNG, or GIF'));
        }
        Test.stopTest();
    }

    @IsTest
    static void validatesPhotoBeforePortalContextCheck() {
        Test.startTest();
        try {
            PortalProfileService.updateProfilePhoto(
                EncodingUtil.base64Encode(Blob.valueOf('test-image')),
                'profile.jpg',
                'image/jpeg'
            );
            System.assert(false, 'Expected the test context to have no Experience Cloud network.');
        } catch (AuraHandledException ex) {
            System.assert(ex.getMessage().contains('Order Portal'));
        }
        Test.stopTest();
    }
}
