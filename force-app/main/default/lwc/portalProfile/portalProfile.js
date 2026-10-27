import { LightningElement, wire } from 'lwc';
import USER_ID from '@salesforce/user/Id';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import FIRST_NAME from '@salesforce/schema/User.FirstName';
import LAST_NAME from '@salesforce/schema/User.LastName';
import MEDIUM_PHOTO_URL from '@salesforce/schema/User.MediumPhotoUrl';
import updateProfilePhoto from '@salesforce/apex/PortalProfileService.updateProfilePhoto';

const USER_FIELDS = [FIRST_NAME, LAST_NAME, MEDIUM_PHOTO_URL];

export default class PortalProfile extends LightningElement {
    userId = USER_ID;
    isOpen = false;
    isUploadingPhoto = false;
    errorMessage;
    successMessage;
    wiredUserRecord;

    @wire(getRecord, { recordId: USER_ID, fields: USER_FIELDS })
    wiredUserRecord(result) {
        this.wiredUserRecord = result;
    }

    get displayName() {
        const firstName = getFieldValue(this.wiredUserRecord?.data, FIRST_NAME) || '';
        const lastName = getFieldValue(this.wiredUserRecord?.data, LAST_NAME) || '';
        return `${firstName} ${lastName}`.trim() || 'Portal User';
    }

    get photoUrl() {
        return getFieldValue(this.wiredUserRecord?.data, MEDIUM_PHOTO_URL);
    }

    openProfile() {
        this.isOpen = true;
        this.errorMessage = undefined;
        this.successMessage = undefined;
    }

    closeProfile() {
        this.isOpen = false;
        this.errorMessage = undefined;
        this.successMessage = undefined;
    }

    handleBackdropClick(event) {
        if (event.target === event.currentTarget) {
            this.closeProfile();
        }
    }

    stopPropagation(event) {
        event.stopPropagation();
    }

    async handlePhotoChange(event) {
        const file = event.target.files?.[0];
        if (!file) {
            return;
        }

        if (!['image/jpeg', 'image/png', 'image/gif'].includes(file.type)) {
            this.errorMessage = 'Please choose a JPG, PNG, or GIF image.';
            event.target.value = null;
            return;
        }

        if (file.size > 5 * 1024 * 1024) {
            this.errorMessage = 'Please choose an image smaller than 5 MB.';
            event.target.value = null;
            return;
        }

        this.isUploadingPhoto = true;
        this.errorMessage = undefined;
        this.successMessage = undefined;

        try {
            const base64Data = await this.readFileAsBase64(file);
            await updateProfilePhoto({
                base64Data,
                fileName: file.name,
                contentType: file.type
            });

            await refreshApex(this.wiredUserRecord);
            this.successMessage = 'Profile picture updated successfully.';
        } catch (error) {
            this.errorMessage = error?.body?.message || error?.message || 'Unable to update your profile picture.';
        } finally {
            this.isUploadingPhoto = false;
            event.target.value = null;
        }
    }

    readFileAsBase64(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => {
                const result = reader.result || '';
                resolve(result.toString().split(',')[1] || '');
            };
            reader.onerror = () => reject(new Error('The selected image could not be read.'));
            reader.readAsDataURL(file);
        });
    }

    handleSaveSuccess() {
        this.errorMessage = undefined;
        this.successMessage = 'Profile details saved successfully.';
    }

    handleSaveError(event) {
        this.successMessage = undefined;
        this.errorMessage = event?.detail?.detail || 'Unable to save your profile details.';
    }
}
