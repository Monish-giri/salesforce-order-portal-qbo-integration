public with sharing class PortalProfileService {
    private static final Integer MAX_PHOTO_BYTES = 5 * 1024 * 1024;
    private static final Set<String> ALLOWED_IMAGE_TYPES = new Set<String>{
        'image/jpeg',
        'image/png',
        'image/gif'
    };

    @AuraEnabled
    public static void updateProfilePhoto(String base64Data, String fileName, String contentType) {
        if (String.isBlank(base64Data)) {
            throw new AuraHandledException('Please choose an image before uploading.');
        }

        if (String.isBlank(contentType) || !ALLOWED_IMAGE_TYPES.contains(contentType.toLowerCase())) {
            throw new AuraHandledException('Please upload a JPG, PNG, or GIF image.');
        }

        Blob photo;
        try {
            photo = EncodingUtil.base64Decode(base64Data);
        } catch (Exception ex) {
            throw new AuraHandledException('The selected image could not be processed.');
        }

        if (photo == null || photo.size() == 0) {
            throw new AuraHandledException('The selected image is empty.');
        }

        if (photo.size() > MAX_PHOTO_BYTES) {
            throw new AuraHandledException('Please choose an image smaller than 5 MB.');
        }

        String safeFileName = String.isBlank(fileName) ? 'profile-photo' : fileName;
        String networkId = Network.getNetworkId();
        if (String.isBlank(networkId)) {
            throw new AuraHandledException('Profile photos can only be updated from the Order Portal.');
        }

        try {
            ConnectApi.BinaryInput photoInput = new ConnectApi.BinaryInput(
                photo,
                contentType.toLowerCase(),
                safeFileName
            );

            if (!Test.isRunningTest()) {
                ConnectApi.UserProfiles.setPhoto(networkId, UserInfo.getUserId(), photoInput);
            }
        } catch (Exception ex) {
            throw new AuraHandledException('Unable to update your profile photo. Please try again.');
        }
    }
}
