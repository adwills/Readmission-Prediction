/* Establish CAS session */
CAS PREDREAD SESSOPTS=(TIMEOUT=1800 LOCALE="EN_US");

/*Show all assigned CAS Libraries in Studio side panel*/
CASLIB _ALL_ ASSIGN; 

/*****************************************************************************/
/********************************* DATA PREP *********************************/
/*****************************************************************************/

/*Load SAS data set from a Base engine library to CAS*/
PROC CASUTIL;
	LOAD DATA=SASDATA.HLS_HOSPITAL_ADMISSIONS_160K OUTCASLIB="CASUSER"
	CASOUT="HOSPITAL_ADMISSIONS";
RUN;

PROC CASUTIL;
   DROPTABLE CASDATA="READMIT_PREP" INCASLIB="CASUSER" QUIET;
   DROPTABLE CASDATA="READMIT_PART" INCASLIB="CASUSER" QUIET;
   DROPTABLE CASDATA="READMIT_IMPUTED" INCASLIB="CASUSER" QUIET;
RUN;

/*Make the readmit flag a human readable binary variable and save it in personal caslib*/
PROC FEDSQL SESSREF=PREDREAD;
	CREATE TABLE CASUSER.READMIT_PREP AS
		SELECT *,
			CASE WHEN READMIT_NUMBER > 0 THEN 'Y'
				ELSE 'N'
				END AS READMIT
		FROM CASUSER.HOSPITAL_ADMISSIONS;
	DROP TABLE CASUSER.HOSPITAL_ADMISSIONS;
QUIT;

/*Make this table visible to all - as a permanent starting point */
PROC CASUTIL OUTCASLIB="CASUSER";   
   PROMOTE CASDATA="READMIT_PREP";
QUIT;

/*Define target and input variables*/
%LET CHAR_INPUT = DISCHARGED_TO;
%LET NUM_INPUT = ORDER_SET_USED LENGTH_OF_STAY NUM_CHRONIC_COND PATIENTAGE;
%LET ALL = &CHAR_INPUT &NUM_INPUT READMIT;
%LET TARGET = READMIT;

/*Partition with indicator 1=Training, 0=Validation*/
PROC PARTITION 
	DATA=CASUSER.READMIT_PREP SAMPPCT=70 PARTIND SEED=20;
	OUTPUT OUT=CASUSER.READMIT_PART;
	BY &TARGET;
RUN;

/*Check counts*/
PROC FEDSQL SESSREF=PREDREAD ;
	SELECT READMIT, _PARTIND_, COUNT(*) AS CT 
	FROM CASUSER.READMIT_PART 
	GROUP BY READMIT, _PARTIND_
	ORDER BY READMIT, _PARTIND_;
QUIT;

/*Promote table to access from other sessions*/
PROC CASUTIL OUTCASLIB="CASUSER";   
   PROMOTE CASDATA="READMIT_PART";
QUIT;

/*Impute Missing Values*/
PROC VARIMPUTE DATA=CASUSER.READMIT_PART;
	INPUT &NUM_INPUT / CTECH=MEDIAN;
	OUTPUT OUT=CASUSER.READMIT_IMPUTED COPYVARS=(_ALL_);
	ODS OUTPUT VARIMPUTEINFO = VARIMPUTEINFO;
RUN;

/*Define input variables following imputation*/
PROC SQL NOPRINT; 
	SELECT DISTINCT RESULTVAR INTO :IMPUTEVAR SEPARATED BY " " FROM VARIMPUTEINFO;
QUIT;

%PUT IMPUTEVAR = &IMPUTEVAR;

/*Promote table to access from other sessions*/
PROC CASUTIL OUTCASLIB="CASUSER";   
   PROMOTE CASDATA="READMIT_IMPUTED";
QUIT;

/* Discriminant analysis for class target */
PROC VARREDUCE DATA=CASUSER.READMIT_IMPUTED TECHNIQUE=DISCRIMINANTANALYSIS;  
	CLASS READMIT &CHAR_INPUT.;
	REDUCE SUPERVISED READMIT=&CHAR_INPUT &IMPUTEVAR / MAXEFFECTS=8;
	ODS OUTPUT SELECTIONSUMMARY=SUMMARY SELECTEDEFFECTS=EFFECTS ;
RUN;

PROC SQL NOPRINT;
	SELECT DISTINCT VARIABLE INTO :SELECTED_CLASS SEPARATED BY " " FROM EFFECTS WHERE TYPE = "CLASS";
	SELECT DISTINCT VARIABLE INTO :SELECTED_INTERVAL SEPARATED BY " " FROM EFFECTS WHERE TYPE = "INTERVAL";
RUN;

%PUT SELECTED_CLASS = &SELECTED_CLASS;
%PUT SELECTED_INTERVAL = &SELECTED_INTERVAL;

/*****************************************************************************/
/********************************* MODELING **********************************/
/*****************************************************************************/

/*Train a Gradient Boosting model and output scored data set*/
PROC GRADBOOST DATA=CASUSER.READMIT_IMPUTED SEED=20 NTREES=800;
	TARGET &TARGET / LEVEL=NOMINAL;
	INPUT &SELECTED_INTERVAL / LEVEL=INTERVAL;
	INPUT &SELECTED_CLASS  / LEVEL=NOMINAL;
	PARTITION ROLEVAR=_PARTIND_(TRAIN='1' VALIDATE='0');
	ODS OUTPUT FITSTATISTICS=FITSTATS;
	OUTPUT OUT=CASUSER._SCORED_GRADBOOST_PROC COPYVARS=(_ALL_);
RUN;

/*Create data set from forest stats output */
DATA FITSTATS;
	SET FITSTATS;
	LABEL TREES     = 'Number of Trees';
	LABEL MISCTRAIN   = 'Training';
	LABEL MISCVALID = 'Validation';
RUN;

/*Plot misclassification as function of number of trees*/
PROC SGPLOT DATA=FITSTATS;
	TITLE "Misclassification Rate v. Number of Trees for Training and Validation";
	SERIES X=TREES Y=MISCTRAIN;
	SERIES X=TREES Y=MISCVALID/
           LINEATTRS=(PATTERN=SHORTDASH THICKNESS=2);
	YAXIS LABEL='Misclassification Rate';
RUN;
TITLE;

/*****************************************************************************/
/******************************** ASSESSMENT *********************************/
/*****************************************************************************/
PROC ASSESS DATA=CASUSER._SCORED_GRADBOOST_PROC;
	INPUT P_READMITY;
	TARGET &TARGET / LEVEL=NOMINAL EVENT='Y';
	FITSTAT PVAR=P_READMITN / PEVENT='N';
	BY _PARTIND_;
	ODS OUTPUT FITSTAT  = GRADBOOST_FITSTAT 
	           ROCINFO  = GRADBOOST_ROCINFO 
	           LIFTINFO = GRADBOOST_LIFTINFO;
RUN;

ODS GRAPHICS ON;

PROC FORMAT;
	VALUE PARTINDLBL 0 = 'Validation' 1 = 'Training';
RUN;
       
/*Construct a ROC chart*/
PROC SGPLOT DATA=GRADBOOST_ROCINFO ASPECT=1;
	TITLE "ROC Curve";
	XAXIS LABEL="False Positive Rate" VALUES=(0 TO 1 BY 0.1);
	YAXIS LABEL="True Positive Rate"  VALUES=(0 TO 1 BY 0.1);
	LINEPARM X=0 Y=0 SLOPE=1 / TRANSPARENCY=.7 LINEATTRS=(PATTERN=34);
	SERIES X=FPR Y=SENSITIVITY /GROUP=_PARTIND_;
	FORMAT _PARTIND_ PARTINDLBL.;
RUN;
      
/*Construct a Lift chart*/
PROC SGPLOT DATA=GRADBOOST_LIFTINFO; 
	TITLE "Lift Chart";
	XAXIS LABEL="Population Percentage";
	YAXIS LABEL="Lift";
	SERIES X=DEPTH Y=LIFT / 
	       GROUP=_PARTIND_ MARKERS MARKERATTRS=(SYMBOL=CIRCLEFILLED);
	FORMAT _PARTIND_ PARTINDLBL.;
RUN;

TITLE;
ODS GRAPHICS OFF;

/*Terminate CAS Sesseion*/
CAS PREDREAD TERMINATE;

/*****************************************************************************/
/********************************* UTILITIES *********************************/
/*****************************************************************************/

/*Gather CAS Actions used in PROCs*/
PROC CAS;
	HISTORY;
RUN;

/*Drop tables*/
PROC CASUTIL;
   DROPTABLE CASDATA="GRADBOOST_PY_SCORED" INCASLIB="CASUSER" QUIET;
   DROPTABLE CASDATA="GRADBOOST_R_SCORED" INCASLIB="CASUSER" QUIET;
RUN;

/*List all CAS sessions for this client*/
cas _all_ list;

/*List all CAS sessions for this user ID*/
cas predread listsessions;

/*Connect to an existing CAS session*/
cas mysess uuid="11444ad3-3df3-a54f-a2bc-be37d13eedf0";

/*Terminate it*/
cas mysess terminate;